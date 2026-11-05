// Pre-gzips large build outputs so the Rust server (ServeDir::precompressed_gzip) and
// static hosts that support it can serve them compressed. tailnet.wasm: 28 MB -> ~6 MB.
import { readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { gzipSync, constants } from "node:zlib";

const dist = new URL("../dist/", import.meta.url).pathname;
const walk = (d) => readdirSync(d).flatMap((f) => (statSync(join(d, f)).isDirectory() ? walk(join(d, f)) : [join(d, f)]));
for (const f of walk(dist)) {
  if (!/\.(wasm|js|css|html|svg|webmanifest|json)$/.test(f) || statSync(f).size < 1024) continue;
  writeFileSync(f + ".gz", gzipSync(readFileSync(f), { level: constants.Z_BEST_COMPRESSION }));
}
console.log("precompressed dist/");
