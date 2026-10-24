# Sequence alignment service for InterMine

A Docker image and compose stack for the small web service that the
BlueGenes **Multiple Sequence Alignment Viewer** tool
(`@intermine/bluegenes-msa-viewer`) needs: it receives the protein
sequences of a gene as FASTA, runs [Clustal Omega](http://www.clustal.org/omega/)
and returns the alignment. One instance serves any number of mines.

InterMine used to host this at `https://sequencealignment.apps.intermine.org`,
and the tool has that address hard coded. That host is gone, so on every
gene with more than one protein the tool shows
"Failed to reach sequence alignment server". The service code is
[intermine/sequence-alignment-service](https://github.com/intermine/sequence-alignment-service)
(Express + `clustal-omega-wrapper`, 2019); `index.js`, `package.json` and
`package-lock.json` here are that code, unchanged. What this repository
adds is the container, the wiring into a mine's nginx, and the one-line
patch that points the installed tool at it.

Companion to [intermineorg/docker_template](https://github.com/intermineorg/docker_template)
(deploys a mine) and [intermineorg/jbrowse](https://github.com/intermineorg/jbrowse)
(the same pattern for JBrowse).

## Contents

| File | Purpose |
|------|---------|
| `Dockerfile` | Node 20 on Debian, `clustalo` from the Debian package (no download from clustal.org at build time), runs as the unprivileged `node` user, health check on `/`. |
| `index.js`, `package.json`, `package-lock.json` | The upstream service, unchanged. `POST /align-sequence` with `{"sequence": "<FASTA>"}` returns `{"error": false, "data": "<aligned FASTA>"}`; `GET /` returns `{"version":1,"api_working":true,"error":false}`. |
| `docker-compose.yml` | One container, `aligner`, port 3000 inside; published on `127.0.0.1:13000` only, for checks from the server. |
| `.env.example` | Copy to `.env` to change that port. |
| `docker-compose.override.yml.example` | Copy to `docker-compose.override.yml` to join the container to each mine's Docker network (step 1 below). |

## Start

```sh
git clone https://github.com/intermineorg/sequence-alignment-service.git ~/intermine/docker/sequence-alignment-service
cd ~/intermine/docker/sequence-alignment-service
docker-compose up -d --build
docker ps --filter name=aligner --format '{{.Names}} {{.Status}}'      # ... (healthy)
curl -s http://localhost:13000/                                        # {"version":1,"api_working":true,"error":false}
printf '{"sequence": ">a\\nMKTAYIAKQR\\n>b\\nMKTAYIAKQRQISFVK"}' | curl -s -X POST -H 'Content-Type: application/json' --data @- http://localhost:13000/align-sequence
```

The last line returns the two toy sequences aligned, with gap characters.

## Wiring it into a mine

The browser talks to the service, so it has to be reachable over HTTPS.
Rather than a new public hostname, each mine's own nginx proxies the path
`/align-sequence` to the container, and the installed tool is pointed at
that same-origin path. Three steps per mine.

1. **Join the container to the mine's frontend network**, so the mine's
   nginx can reach it as `http://aligner:3000`. `docker-compose.override.yml.example`
   is the template: it lists HumanMine and FlyMine, each twice, once under
   `services.aligner.networks` and once under the top-level `networks:` as
   `external: true`. Replace those with your own mines' networks. A mine
   deployed from `docker_template` has a network called
   `<directory name>_frontend`; list them with
   `docker network ls --filter name=frontend`.

   ```sh
   cp docker-compose.override.yml.example docker-compose.override.yml
   $EDITOR docker-compose.override.yml      # one mine per entry, in both places
   docker-compose up -d
   docker inspect aligner -f '{{range $k,$v := .NetworkSettings.Networks}}{{$k}} {{end}}'
   ```

   The inspect line must list every mine's network plus
   `sequence-alignment-service_default`. A network name that does not exist
   stops the container with `network <name> declared as external, but could
   not be found`. On dx (HumanMine and FlyMine) the example can be copied
   unchanged.

2. **Route `/align-sequence` in the mine's nginx.** Mines deployed from
   `docker_template` already have this in `nginx/nginx.conf.template`. For
   any other nginx in front of a mine, add inside the `server` block:

   ```nginx
   location = /align-sequence {
       resolver 127.0.0.11 valid=10s ipv6=off;
       set $aligner http://aligner:3000;
       proxy_pass $aligner;
       proxy_set_header Host $host;
   }
   ```

   The upstream is a runtime-resolved variable, so the mine's nginx starts
   and serves normally even while no `aligner` container exists (the tool
   then gets a 502 and shows its error message). Rebuild the mine's nginx
   (`docker-compose up -d --build nginx` in the mine directory) and check:

   ```sh
   curl -s -X POST -H 'Content-Type: application/json' -d '{"sequence":">a\nMKTAYIAKQR\n>b\nMKTAYIAKQRQISFVK"}' https://www.humanmine.org/align-sequence
   ```

3. **Patch the installed tool.** Two edits to the tool's built bundle, in
   the mine's tools directory (mounted at `./data/tools` in
   `docker_template`). The first replaces the hard-coded server address with
   the empty string, so the tool calls `/align-sequence` on the page's own
   origin. The second fixes a bug in the bundled `msa` library that breaks
   it in every browser released since 2021: its check `!t instanceof Array
   || "at" in t` was meant to detect a Backbone collection, but
   `Array.prototype.at` now exists, so plain arrays take the collection
   branch and the viewer dies with `TypeError: t.on is not a function`.

   ```sh
   cd ~/intermine/docker/humanmine
   for f in $(grep -rl 'https://sequencealignment.apps.intermine.org' data/tools/); do
       cp "$f" "$f.bak-aligner"
       sed -i -e 's#"https://sequencealignment.apps.intermine.org"#""#' \
              -e 's#!t instanceof Array||"at"in t#!(t instanceof Array)#' "$f"
       echo "patched $f"
   done
   grep -c '!(t instanceof Array)' data/tools/@intermine/bluegenes-msa-viewer/dist/bundle.js   # 1
   ```

   The first expression matches `dist/bundle.js` (what browsers load) and
   the tool's shipped source file `src/sequence-align-service.js`, which is
   never served but is patched too so the two agree; the second matches
   only the bundle. No restart is needed. Browsers may hold the old bundle
   in cache: reload with cache bypass (Ctrl+Shift+R, or close every private
   window and open a new one), then view a gene with several proteins
   (HumanMine PAX6, `/humanmine/report/Gene/1234788`, has five). If two
   mines share one tools directory through a symlink, patch it once.

   Reinstalling or updating the tool from the BlueGenes admin page restores
   the original bundle, so keep a note of these edits. The upstream fixes
   are for the tool to read the address from its `config.json` and to
   update its `msa` dependency; see
   [the tool's repository](https://github.com/intermine/bluegenes-msa-viewer).

## Undoing

Per mine, in the opposite order: restore the tool bundles from the
`.bak-aligner` copies (or reinstall the tool), remove the
`location = /align-sequence` block from the mine's nginx and rebuild it, and
delete the mine's two lines from `docker-compose.override.yml` here followed
by `docker-compose up -d`. To remove the service altogether:
`docker-compose down --rmi local`.

## Notes

- Clustal Omega runs on the server's CPU for every request. The requests
  are tiny (the proteins of one gene) and take well under a second, and the
  path is only reachable through the mines' nginx, not on a public port.
- The sandbox the image was first built in is arm64; the Debian package
  exists for both arm64 and amd64, so the same Dockerfile builds on either.

## License

ISC, as the upstream service. See `LICENSE`.
