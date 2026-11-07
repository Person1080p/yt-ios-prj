/** YouTube / YouTube Music links typed or pasted into the search box. */
export type YouTubeLink =
  /** `list`: the playlist the link was opened from, if any. */
  | { kind: "video"; videoId: string; list?: string }
  | { kind: "playlist"; id: string }
  | { kind: "album"; id: string }
  | { kind: "artist"; id: string };

const VIDEO_ID = /^[\w-]{11}$/;
const LIST_ID = /^[\w-]{2,128}$/;

/** What a YouTube link points to, or null when the text isn't one. */
export function parseYouTubeLink(text: string): YouTubeLink | null {
  const s = text.trim();
  if (!s || /\s/.test(s)) return null;
  let url: URL;
  try {
    url = new URL(/^https?:\/\//i.test(s) ? s : `https://${s}`);
  } catch {
    return null;
  }
  const host = url.hostname.toLowerCase().replace(/^(www|m)\./, "");
  if (host !== "youtu.be" && host !== "youtube.com" && host !== "music.youtube.com" && host !== "youtube-nocookie.com") return null;

  const parts = url.pathname.split("/").filter(Boolean);
  const v = url.searchParams.get("v");
  const rawList = url.searchParams.get("list");
  const list = rawList && LIST_ID.test(rawList) ? rawList : undefined;
  // Mixes ("RD…") are radios generated around the video, not playlists worth opening on their own.
  const realList = list && !list.startsWith("RD") ? list : undefined;

  let videoId: string | undefined;
  if (host === "youtu.be") videoId = parts[0];
  else if (parts[0] === "watch") videoId = v ?? undefined;
  else if (["shorts", "embed", "live", "v"].includes(parts[0])) videoId = parts[1];
  if (videoId && VIDEO_ID.test(videoId)) return { kind: "video", videoId, ...(realList ? { list: realList } : {}) };

  if (parts[0] === "playlist" && list) return { kind: "playlist", id: list };
  if (parts[0] === "browse" && parts[1]) {
    const id = parts[1];
    if (id.startsWith("MPRE")) return { kind: "album", id };
    if (id.startsWith("VL") && LIST_ID.test(id)) return { kind: "playlist", id: id.slice(2) };
    if (id.startsWith("UC")) return { kind: "artist", id };
  }
  if (parts[0] === "channel" && parts[1]?.startsWith("UC")) return { kind: "artist", id: parts[1] };
  if (list) return { kind: "playlist", id: list };
  return null;
}

/** The app page a non-video link opens. */
export function linkPath(link: Exclude<YouTubeLink, { kind: "video" }>): string {
  switch (link.kind) {
    // No title: the collection page looks it up.
    case "playlist":
    case "album":
      return `/collection/${encodeURIComponent(link.id)}`;
    case "artist":
      return `/artist/${encodeURIComponent(link.id)}`;
  }
}
