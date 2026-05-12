"""Vision upload and analysis routes."""

from __future__ import annotations

import logging

from fastapi import APIRouter, File, Form, Request, UploadFile
from fastapi.responses import JSONResponse

from ..models.schemas import (
    FrameAnalysisResponse,
    VisionAnalysisResponse,
    VisionProxyRequest,
    VisionProxyResponse,
)
from ..services.vision_service import (
    analyze_image_with_provider_fallback,
    analyze_uploaded_frame,
    analyze_uploaded_image,
    decode_base64_image,
)
from ..utils.errors import AppError

logger = logging.getLogger(__name__)
router = APIRouter(prefix="/api/vision", tags=["vision"])
legacy_router = APIRouter(tags=["vision"])


@router.post("/analyze", response_model=VisionProxyResponse)
@legacy_router.post("/vision/analyze", response_model=VisionProxyResponse)
async def analyze_image(
    request: Request,
    file: UploadFile | None = File(default=None),
    prompt: str | None = Form(default=None),
    scene_summary: str | None = Form(default=None),
    model: str | None = Form(default=None),
) -> VisionProxyResponse:
    """Accept a file upload or base64 JSON payload for Gemini-first image analysis."""

    image_bytes = await _resolve_image_bytes(request=request, file=file)
    payload = await _resolve_request_payload(
        request=request,
        prompt=prompt,
        scene_summary=scene_summary,
        model=model,
    )
    response = analyze_image_with_provider_fallback(
        image_bytes=image_bytes,
        prompt=payload.prompt,
        scene_summary=payload.scene_summary,
        model=payload.model,
    )
    logger.info("Vision analyze response: %s", response.model_dump_json())
    return response


@legacy_router.post("/analyze-frame", response_model=FrameAnalysisResponse)
async def analyze_frame(file: UploadFile | None = File(default=None)) -> JSONResponse:
    """Analyze a multipart-uploaded image frame and return safe JSON."""

    if file is None:
        return JSONResponse(
            status_code=400,
            content={"error": "missing image upload"},
        )

    result = await analyze_uploaded_frame(file)
    if result.error and not result.scene:
        return JSONResponse(
            status_code=200,
            content=result.model_dump(),
        )
    return JSONResponse(status_code=200, content=result.model_dump())


@legacy_router.post("/api/vision/upload-placeholder", response_model=VisionAnalysisResponse)
def analyze_image_placeholder(file: UploadFile = File(...)) -> VisionAnalysisResponse:
    """Preserve the older placeholder upload analysis flow."""

    return analyze_uploaded_image(file)


async def _resolve_image_bytes(request: Request, file: UploadFile | None) -> bytes:
    """Extract image bytes from multipart upload or JSON base64 payload."""

    if file is not None:
        logger.info(
            "Received multipart /vision/analyze request: filename=%s content_type=%s",
            file.filename or "unknown",
            file.content_type or "unknown",
        )
        return await file.read()

    content_type = request.headers.get("content-type", "")
    if "application/json" not in content_type.lower():
        raise AppError("Provide an image file upload or JSON with image_base64.", status_code=400)

    body = await request.json()
    payload = VisionProxyRequest.model_validate(body)
    if not payload.image_base64:
        raise AppError("image_base64 is required when no file is uploaded.", status_code=400)

    logger.info("Received JSON /vision/analyze request with base64 image.")
    return decode_base64_image(payload.image_base64)


async def _resolve_request_payload(
    request: Request,
    prompt: str | None,
    scene_summary: str | None,
    model: str | None,
) -> VisionProxyRequest:
    """Build a unified payload regardless of transport type."""

    content_type = request.headers.get("content-type", "")
    if "application/json" in content_type.lower():
        body = await request.json()
        payload = VisionProxyRequest.model_validate(body)
        return payload

    return VisionProxyRequest(
        prompt=prompt,
        scene_summary=scene_summary,
        model=model,
    )
