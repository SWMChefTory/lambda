from fastapi import FastAPI, Request, Response

# Lambda handler import
from app.caption.client_lambda import handler as lambda_handler

app = FastAPI()

@app.get("/health")
def health():
    return {"ok": True}

@app.api_route("/", methods=["POST", "OPTIONS"])
async def root(request: Request):
    body_bytes = await request.body()
    body_str = body_bytes.decode("utf-8", errors="ignore") if body_bytes else ""

    # Lambda event 형태(간단 버전)
    event = {
        "headers": dict(request.headers),
        "queryStringParameters": dict(request.query_params),
        "requestContext": {
            "http": {"method": request.method, "path": str(request.url.path)}
        },
        "body": body_str,
        "isBase64Encoded": False,
    }

    res = lambda_handler(event, None) or {}
    status = int(res.get("statusCode", 200))
    headers = res.get("headers") or {}
    body = res.get("body") or ""

    return Response(
        content=body,
        status_code=status,
        headers=headers,
        media_type=headers.get("Content-Type"),
    )
