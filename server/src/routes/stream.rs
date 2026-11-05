//! Audio delivery. Plex is preferred when the same track exists in the library;
//! otherwise audio comes from YouTube through yt-dlp.

use axum::{
    body::Body,
    extract::{Path, Query, State},
    http::{header, HeaderMap, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
    Json,
};
use serde::{Deserialize, Serialize};
use tokio_util::io::ReaderStream;

use crate::{
    error::{ApiResult, AppError},
    routes::music::track_or_fetch,
    services::plex::PlexTrack,
    state::SharedState,
};

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct SourceInfo {
    /// plex | youtube
    source: String,
    plex: Option<PlexTrack>,
}

async fn plex_match(st: &SharedState, video_id: &str) -> Option<PlexTrack> {
    if !st.plex.enabled().await {
        return None;
    }
    let track = track_or_fetch(st, video_id).await.ok()?;
    match st.plex.find_match(&track).await {
        Ok(m) => m,
        Err(e) => {
            tracing::warn!("plex match failed for {video_id}: {e:#}");
            None
        }
    }
}

pub async fn source(State(st): State<SharedState>, Path(video_id): Path<String>) -> ApiResult<SourceInfo> {
    let plex = plex_match(&st, &video_id).await;
    Ok(Json(SourceInfo { source: if plex.is_some() { "plex" } else { "youtube" }.into(), plex }))
}

#[derive(Deserialize)]
pub struct StreamQuery {
    /// Force a source: `youtube` skips the Plex lookup, `pipe` streams yt-dlp's stdout directly.
    #[serde(default)]
    via: Option<String>,
}

pub async fn stream(
    State(st): State<SharedState>,
    Path(video_id): Path<String>,
    Query(q): Query<StreamQuery>,
    headers: HeaderMap,
) -> Result<Response, AppError> {
    if !video_id.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_') || video_id.len() > 20 {
        return Err(AppError::bad("invalid video id"));
    }
    let range = headers.get(header::RANGE).cloned();

    if q.via.is_none() {
        if let Some(pt) = plex_match(&st, &video_id).await {
            let url = st.plex.stream_url(&pt).await?;
            match proxy(&st.http, &url, range.clone(), &[], None).await {
                Ok(resp) => return Ok(with_source(resp, "plex")),
                Err(e) => tracing::warn!("plex stream failed, falling back to youtube: {e:#}"),
            }
        }
    }

    if q.via.as_deref() != Some("pipe") {
        for attempt in 0..2 {
            let resolved = match st.ytdlp.resolve(&video_id).await {
                Ok(r) => r,
                Err(e) => {
                    tracing::warn!("yt-dlp resolve {video_id}: {e:#}");
                    break;
                }
            };
            let extra: Vec<(String, String)> = resolved
                .headers
                .iter()
                .filter(|(k, _)| matches!(k.to_ascii_lowercase().as_str(), "user-agent" | "accept-language" | "referer" | "origin"))
                .map(|(k, v)| (k.clone(), v.clone()))
                .collect();
            match proxy(&st.http, &resolved.url, range.clone(), &extra, Some(&resolved.mime)).await {
                Ok(resp) => return Ok(with_source(resp, "youtube")),
                Err(e) => {
                    tracing::warn!("googlevideo proxy failed (attempt {attempt}): {e:#}");
                    st.ytdlp.invalidate(&video_id).await;
                }
            }
        }
    }

    // Last resort: pipe yt-dlp's output. No seeking, but works when direct URLs are blocked.
    let mut child = st.ytdlp.pipe(&video_id).await?;
    let stdout = child.stdout.take().ok_or_else(|| anyhow::anyhow!("no stdout"))?;
    let stream = ReaderStream::new(stdout);
    // Keep the child alive for as long as the body is streaming; it is killed on drop.
    let body = Body::from_stream(futures::StreamExt::map(stream, move |chunk| {
        let _keep = &child;
        chunk
    }));
    let mut resp = Response::new(body);
    resp.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_static("audio/mp4"));
    resp.headers_mut().insert(header::ACCEPT_RANGES, HeaderValue::from_static("none"));
    Ok(with_source(resp, "youtube"))
}

fn with_source(mut resp: Response, source: &'static str) -> Response {
    resp.headers_mut().insert("x-audio-source", HeaderValue::from_static(source));
    resp.headers_mut().insert(header::CACHE_CONTROL, HeaderValue::from_static("private, max-age=3600"));
    resp
}

/// Forward a (possibly ranged) GET, streaming the body back.
async fn proxy(
    http: &reqwest::Client,
    url: &str,
    range: Option<HeaderValue>,
    extra: &[(String, String)],
    mime: Option<&str>,
) -> anyhow::Result<Response> {
    let mut req = http.get(url);
    if let Some(r) = range {
        req = req.header(header::RANGE, r);
    }
    for (k, v) in extra {
        req = req.header(k.as_str(), v.as_str());
    }
    let upstream = req.send().await?;
    let status = upstream.status();
    if !(status.is_success() || status == StatusCode::RANGE_NOT_SATISFIABLE) {
        anyhow::bail!("upstream returned {status}");
    }

    let mut builder = Response::builder().status(status.as_u16());
    for name in [header::CONTENT_LENGTH, header::CONTENT_RANGE, header::ACCEPT_RANGES, header::LAST_MODIFIED, header::ETAG] {
        if let Some(v) = upstream.headers().get(name.as_str()) {
            builder = builder.header(name, v.as_bytes());
        }
    }
    let ct = mime
        .map(String::from)
        .or_else(|| upstream.headers().get("content-type").and_then(|v| v.to_str().ok()).map(String::from))
        .unwrap_or_else(|| "application/octet-stream".into());
    builder = builder.header(header::CONTENT_TYPE, ct);
    if !upstream.headers().contains_key("accept-ranges") {
        builder = builder.header(header::ACCEPT_RANGES, "bytes");
    }
    Ok(builder.body(Body::from_stream(upstream.bytes_stream()))?.into_response())
}
