import base64
import glob
import json
import logging
import os
import shutil
import stat
import subprocess
from typing import Optional, Tuple
from urllib.parse import parse_qs, urlparse

import requests

from app.caption.exception import CaptionErrorCode, CaptionException


# ────────────────────────────────────────────────
# Logging
# ────────────────────────────────────────────────
def setup_logging():
    level_name = os.getenv("LOG_LEVEL", "INFO").upper()
    level = getattr(logging, level_name, logging.INFO)

    root = logging.getLogger()
    root.setLevel(level)

    for h in root.handlers:
        h.setLevel(level)

    logging.getLogger("botocore").setLevel(logging.WARNING)
    logging.getLogger("urllib3").setLevel(logging.WARNING)


setup_logging()

# Ensure Lambda layers binaries are discoverable (deno/yt-dlp/ffmpeg in /opt/bin)
os.environ["PATH"] = "/opt/bin:" + os.environ.get("PATH", "")

CORS_HEADERS = {"Access-Control-Allow-Origin": "*"}
JSON_HEADERS = {
    "Content-Type": "application/json; charset=utf-8",
    "Access-Control-Allow-Origin": "*",
}
OPTIONS_HEADERS = {
    "Access-Control-Allow-Origin": "*",
    "Access-Control-Allow-Methods": "POST,OPTIONS",
    "Access-Control-Allow-Headers": "Content-Type,Authorization",
}


# ────────────────────────────────────────────────
# yt-dlp 쿠키 파일
# ────────────────────────────────────────────────
def get_cookiefile() -> Optional[str]:
    """
    Secret으로 마운트된 cookies.txt(src)를 /tmp(dst)로 복사해서 yt-dlp에 전달.
    쿠키 "값"은 절대 로그로 남기지 말고, 존재/크기만 남긴다.
    """
    log = logging.getLogger(__name__)

    src = os.environ.get("YTDLP_COOKIES", "/var/task/assets/yt_cookies/cookies.txt")
    dst = "/tmp/cookies.txt"

    if not os.path.exists(src):
        log.warning("[cookies] src missing | src=%s", src)
        return None

    try:
        log.info("[cookies] src ok | src=%s size=%d", src, os.path.getsize(src))
    except Exception as e:
        log.info("[cookies] src ok | src=%s size=? err=%s", src, e)

    try:
        shutil.copyfile(src, dst)
        os.chmod(dst, stat.S_IRUSR | stat.S_IWUSR)  # 0o600
        log.info("[cookies] copied | dst=%s size=%d", dst, os.path.getsize(dst))
        return dst
    except Exception as e:
        # 복사 실패 시에는 src를 그대로 쓰도록 fallback
        log.exception("[cookies] copy failed | src=%s dst=%s err=%s", src, dst, e)
        return src


def yt_dlp_base_args(*, verbose: bool = False) -> list:
    """
    /opt/bin/yt-dlp 바이너리를 subprocess로 호출하기 위한 공통 args.
    """
    args = [
        "yt-dlp",
        "--force-ipv4",
        "--no-playlist",
        "--socket-timeout",
        str(int(os.environ.get("YTDLP_SOCKET_TIMEOUT", "30"))),
        "--retries",
        str(int(os.environ.get("YTDLP_RETRIES", "5"))),
        "--fragment-retries",
        str(int(os.environ.get("YTDLP_FRAGMENT_RETRIES", "5"))),
    ]

    cookiefile = get_cookiefile()
    if cookiefile:
        args += ["--cookies", cookiefile]

    # ffmpeg/ffprobe are in /opt/bin when layer is attached
    # This helps yt-dlp find them even if PATH is restricted.
    if os.path.exists("/opt/bin/ffmpeg"):
        args += ["--ffmpeg-location", "/opt/bin"]

    if verbose:
        args += ["-v"]
    else:
        args += ["--quiet", "--no-warnings"]

    return args


# ────────────────────────────────────────────────
# Google AI Studio (Gemini API) - Files API 업로드
# ────────────────────────────────────────────────
def gemini_files_upload_resumable(file_path: str, mime_type: str) -> dict:
    """
    AI Studio Files API resumable upload.
    Returns JSON payload (contains file.uri).
    """
    api_key = os.environ["GEMINI_API_KEY"]
    base_url = "https://generativelanguage.googleapis.com"
    start_url = f"{base_url}/upload/v1beta/files?key={api_key}"

    num_bytes = os.path.getsize(file_path)
    display_name = os.path.basename(file_path)

    # start
    start_headers = {
        "X-Goog-Upload-Protocol": "resumable",
        "X-Goog-Upload-Command": "start",
        "X-Goog-Upload-Header-Content-Length": str(num_bytes),
        "X-Goog-Upload-Header-Content-Type": mime_type,
        "Content-Type": "application/json",
    }
    start_body = {"file": {"display_name": display_name}}

    r = requests.post(start_url, headers=start_headers, json=start_body, timeout=30)
    r.raise_for_status()

    upload_url = r.headers.get("x-goog-upload-url") or r.headers.get("X-Goog-Upload-URL")
    if not upload_url:
        raise RuntimeError("Missing x-goog-upload-url in response headers")

    # upload + finalize
    with open(file_path, "rb") as f:
        upload_headers = {
            "Content-Length": str(num_bytes),
            "X-Goog-Upload-Offset": "0",
            "X-Goog-Upload-Command": "upload, finalize",
        }
        r2 = requests.post(upload_url, headers=upload_headers, data=f, timeout=600)
        r2.raise_for_status()
        return r2.json()


# ────────────────────────────────────────────────
# CaptionClient (기존 자막 + 영상 다운로드 추가)
# ────────────────────────────────────────────────
class CaptionClient:
    def __init__(self):
        self.logger = logging.getLogger(__name__)

    # 새 외부 호출: 영상 다운로드 (/tmp)
    def download_video_to_tmp(self, video_id: str) -> Tuple[str, str]:
        """
        Download video file to /tmp and return (path, mime_type)
        """
        url = f"https://www.youtube.com/watch?v={video_id}"
        outtmpl = f"/tmp/{video_id}.%(ext)s"

        # With ffmpeg available, you can use bestvideo+bestaudio merge.
        # If you hit issues, fallback to "best[ext=mp4]/best".
        fmt = os.environ.get(
            "YTDLP_FORMAT",
            "bestvideo[height<=720][ext=mp4]+bestaudio[ext=m4a]/best[ext=mp4][height<=720]/best[height<=720]/best",
        )

        self.logger.info(f"[VIDEO] ▶ yt-dlp 다운로드 시작 | video_id={video_id} | format={fmt}")

        cmd = yt_dlp_base_args(verbose=True) + [
            "-f",
            fmt,
            "-o",
            outtmpl,
            "--merge-output-format",
            "mp4",
            url,
        ]

        subprocess.check_call(cmd)

        files = glob.glob(f"/tmp/{video_id}.*")
        if not files:
            raise CaptionException(CaptionErrorCode.CAPTION_EXTRACT_FAILED)

        files.sort(key=lambda p: (0 if p.endswith(".mp4") else 1, p))
        path = files[0]

        # Files API 2GB 상한 전에 컷 (기본: 2GB-10MB)
        max_bytes = int(os.environ.get("MAX_VIDEO_BYTES", str(2 * 1024 * 1024 * 1024 - 10_000_000)))
        size = os.path.getsize(path)
        if size > max_bytes:
            self.logger.error(f"[VIDEO] ▶ 파일 너무 큼 | size={size} | max={max_bytes} | path={path}")
            raise CaptionException(CaptionErrorCode.CAPTION_EXTRACT_FAILED)

        mime = "video/mp4" if path.endswith(".mp4") else "application/octet-stream"
        return path, mime


# ────────────────────────────────────────────────
# Handler helpers
# ────────────────────────────────────────────────
def _extract_payload(event: dict) -> dict:
    if "body" in event:
        raw_body = event["body"]
        if event.get("isBase64Encoded"):
            raw_body = base64.b64decode(raw_body).decode("utf-8", errors="ignore")
        try:
            return json.loads(raw_body) if raw_body else {}
        except json.JSONDecodeError:
            return {}
    return event or {}


def _extract_video_id(payload: dict) -> Optional[str]:
    video_id = payload.get("video_id")
    if video_id:
        return video_id
    video_url = payload.get("video_url")
    if video_url:
        qs = parse_qs(urlparse(video_url).query or "")
        return (qs.get("v") or [None])[0]
    return None


def _json_response(status_code: int, body: dict, headers: Optional[dict] = None) -> dict:
    return {
        "statusCode": status_code,
        "headers": headers or JSON_HEADERS,
        "body": json.dumps(body),
    }


# ────────────────────────────────────────────────
# Handler
# ────────────────────────────────────────────────
def handler(event, context):
    logger = logging.getLogger(__name__)

    # Optional: toolchain sanity check (set DEBUG_TOOLS=1 to enable)
    if os.environ.get("DEBUG_TOOLS") == "1":
        try:
            logger.info("[PATH] %s", os.environ["PATH"])
            logger.info("[which] deno=%s", subprocess.check_output(["/bin/sh", "-lc", "which deno || true"], text=True).strip())
            logger.info("[which] yt-dlp=%s", subprocess.check_output(["/bin/sh", "-lc", "which yt-dlp || true"], text=True).strip())
            logger.info("[which] ffmpeg=%s", subprocess.check_output(["/bin/sh", "-lc", "which ffmpeg || true"], text=True).strip())

            logger.info("[deno] %s", subprocess.check_output(["deno", "--version"], text=True).splitlines()[0])
            logger.info("[ytdlp] %s", subprocess.check_output(["yt-dlp", "--version"], text=True).strip())
            logger.info("[ffmpeg] %s", subprocess.check_output(["ffmpeg", "-version"], text=True).splitlines()[0])
        except Exception as e:
            logger.warning("[DEBUG_TOOLS] check failed: %s", e)

    try:
        # CORS preflight
        if event.get("requestContext", {}).get("http", {}).get("method") == "OPTIONS":
            return {
                "statusCode": 200,
                "headers": OPTIONS_HEADERS,
                "body": "",
            }

        payload = _extract_payload(event)
        action = (payload.get("action") or "upload").lower()

        video_id = _extract_video_id(payload)
        if not video_id:
            logger.error(f"[Handler] ▶ video id가 없습니다. | event={event}")
            return _json_response(400, {"error": "video_id or video_url required"})

        client = CaptionClient()

        # 2) 새 기능: Gemini에 업로드 후 file.uri 반환
        if action == "upload":
            if not os.environ.get("GEMINI_API_KEY"):
                return _json_response(500, {"error": "GEMINI_API_KEY_NOT_SET"}, headers=CORS_HEADERS)

            # 1) yt-dlp 다운로드
            video_path, mime = client.download_video_to_tmp(video_id)

            try:
                # 2) Files API 업로드
                upload_resp = gemini_files_upload_resumable(video_path, mime)
                file_obj = upload_resp.get("file") or {}
                file_uri = file_obj.get("uri")
                file_name = file_obj.get("name")  # files/{id} 형태
                file_mime = file_obj.get("mimeType") or mime

                if not file_uri:
                    raise RuntimeError("Upload succeeded but file.uri missing")

            finally:
                # /tmp 정리
                try:
                    os.remove(video_path)
                except Exception:
                    pass

            return _json_response(
                200,
                {
                    "video_id": video_id,
                    "file_uri": file_uri,
                    "file_name": file_name,
                    "mime_type": file_mime,
                },
            )

        return _json_response(400, {"error": "invalid action", "allowed": ["upload"]})

    except CaptionException as ce:
        status = 500
        logger.error(f"[Handler] ▶ CaptionException | code={ce.code} | msg={ce.message} | status={status}")
        return {
            "statusCode": status,
            "headers": CORS_HEADERS,
            "body": json.dumps({"error": ce.code}),
        }

    except requests.HTTPError as e:
        logger.error(f"[Handler] ▶ HTTPError | error={e} | body={getattr(e.response, 'text', '')}")
        return {
            "statusCode": 502,
            "headers": CORS_HEADERS,
            "body": json.dumps({"error": "UPSTREAM_HTTP_ERROR"}),
        }

    except Exception as e:
        logger.error(f"[Handler] ▶ Unhandled error | error={e}")
        return {
            "statusCode": 500,
            "headers": CORS_HEADERS,
            "body": json.dumps({"error": "INTERNAL_ERROR"}),
        }
