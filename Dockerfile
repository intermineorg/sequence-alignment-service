# Sequence alignment service for the BlueGenes MSA viewer.
# Code: https://github.com/intermine/sequence-alignment-service (Express +
# clustal-omega-wrapper), vendored here unchanged as index.js/package*.json.
# Clustal Omega comes from the Debian package rather than the wrapper's
# postinstall download from clustal.org, so the build does not depend on
# that site being up.
FROM node:20-bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends clustalo \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app
COPY package.json package-lock.json index.js ./
# --ignore-scripts skips the postinstall that would download clustalo.
# The wrapper writes its temporary FASTA files into its own lib/ directory,
# so that directory must be writable by the unprivileged user.
RUN npm ci --omit=dev --ignore-scripts \
 && mkdir bin && ln -s /usr/bin/clustalo bin/clustalo \
 && chown node:node node_modules/clustal-omega-wrapper/lib

ENV PORT=3000
EXPOSE 3000
USER node
HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:3000/').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "index.js"]
