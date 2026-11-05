//! Album art cache: `/api/art?u=<image url>` downloads artwork once, keeps it on disk under
//! `<data>/art/`, and serves it from there with long-lived cache headers. Only artwork hosts
//! are allowed, so this can't be used as an open proxy.

use axum::{
    body::Body,
    extract::{Query, State},
    http::{header, HeaderValue, StatusCode},
    response::{IntoResponse, Response},
};
use serde::Deserialize;
use sha2::{Digest, Sha256};

use crate::{error::AppError, state::SharedState};

const MAX_BYTES: usize = 5 * 1024 * 1024;
const ALLOWED_HOSTS: &[&str] = &["googleusercontent.com", "ggpht.com", "ytimg.com", "lastfm.freetls.fastly.net", "last.fm"];

#[derive(Deserialize)]
pub struct ArtQuery {
    u: String,
}

fn sniff(bytes: &[u8]) -> &'static str {
    match bytes {
        [0xFF, 0xD8, ..] => "image/jpeg",
        [0x89, b'P', b'N', b'G', ..] => "image/png",
        [b'R', b'I', b'F', b'F', _, _, _, _, b'W', b'E', b'B', b'P', ..] => "image/webp",
        [b'G', b'I', b'F', ..] => "image/gif",
        _ => "application/octet-stream",
    }
}

fn image_response(bytes: Vec<u8>) -> Response {
    let mut resp = Response::new(Body::from(bytes.clone()));
    resp.headers_mut().insert(header::CONTENT_TYPE, HeaderValue::from_static(sniff(&bytes)));
    resp.headers_mut()
        .insert(header::CACHE_CONTROL, HeaderValue::from_static("public, max-age=31536000, immutable"));
    resp
}

pub async fn art(State(st): State<SharedState>, Query(q): Query<ArtQuery>) -> Result<Response, AppError> {
    let url = reqwest::Url::parse(&q.u).map_err(|_| AppError::bad("invalid url"))?;
    let host = url.host_str().unwrap_or_default();
    if url.scheme() != "https" || !ALLOWED_HOSTS.iter().any(|h| host == *h || host.ends_with(&format!(".{h}"))) {
        return Err(AppError::bad("not an artwork url"));
    }

    let dir = st.cfg.data_dir.join("art");
    let name = hex::encode(Sha256::digest(q.u.as_bytes()));
    let path = dir.join(&name[..2]).join(&name);
    if let Ok(bytes) = tokio::fs::read(&path).await {
        return Ok(image_response(bytes));
    }

    let resp = st.http.get(url).send().await?;
    if !resp.status().is_success() {
        return Ok((StatusCode::BAD_GATEWAY, "artwork unavailable").into_response());
    }
    let bytes = resp.bytes().await?;
    if bytes.len() > MAX_BYTES || !sniff(&bytes).starts_with("image/") {
        return Ok((StatusCode::BAD_GATEWAY, "not an image").into_response());
    }
    if let Some(parent) = path.parent() {
        let _ = tokio::fs::create_dir_all(parent).await;
    }
    let tmp = path.with_extension("tmp");
    if tokio::fs::write(&tmp, &bytes).await.is_ok() {
        let _ = tokio::fs::rename(&tmp, &path).await;
    }
    Ok(image_response(bytes.to_vec()))
}
