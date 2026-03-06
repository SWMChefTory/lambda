FROM asia-northeast3-docker.pkg.dev/project-25290f24-aa2a-4be3-8d3/base/python-ytdlp-deno:nightly
ENV DEBIAN_FRONTEND=noninteractive

# Lambda 호환: /opt/bin에 바이너리 노출
RUN mkdir -p /opt/bin  && ln -sf /usr/local/bin/yt-dlp /opt/bin/yt-dlp  && (command -v deno >/dev/null 2>&1 && ln -sf "$(command -v deno)" /opt/bin/deno || true)  && ln -sf /usr/bin/ffmpeg /opt/bin/ffmpeg

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY main.py .
COPY app ./app

ENV PORT=8080
CMD ["uvicorn", "main:app", "--host", "0.0.0.0", "--port", "8080"]
