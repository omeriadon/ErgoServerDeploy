# Ergo's translation server, with Claude Code and Codex. The build context is the repository root, since it needs ../ErgoKit:
#
#   docker build -f ErgoServer/Dockerfile -t ergo-server .
#   docker run -p 8080:8080 -v ergo-data:/data ergo-server
#
# Two users: the server runs as `ergo`, and every CLI call runs as `ergo-runner`, which can't read /data.
# The server starts with three capabilities (setuid, setgid, chown) so it can switch to the runner with setpriv,
# and hand each run directory over with chown before the call and take it back afterwards.

ARG SWIFT_IMAGE=swift:6.4-noble
ARG RUN_IMAGE=ubuntu:noble

# MARK: - Build

FROM ${SWIFT_IMAGE} AS build
WORKDIR /src

COPY ErgoKit/ ErgoKit/
COPY ErgoServer/ ErgoServer/

# .build lives in a cache mount that outlasts each build, so a change only recompiles what it touches.
# Package.resolved is used as committed, so a deploy never spends time resolving and never picks up a new dependency.
RUN --mount=type=cache,id=ergo-server-build,target=/src/ErgoServer/.build \
	cd ErgoServer \
	&& swift build -c release --product ErgoServer --static-swift-stdlib --force-resolved-versions \
	&& bin="$(swift build -c release --show-bin-path --force-resolved-versions)" \
	&& mkdir /staging \
	&& cp "$bin/ErgoServer" /staging/ \
	&& find -L "$bin" -maxdepth 1 \( -name '*.bundle' -o -name '*.resources' \) -exec cp -RL {} /staging/ \; \
	&& test -d /staging/ErgoServer_ErgoServer.bundle

# MARK: - Run

FROM ${RUN_IMAGE}
ARG CLAUDE_CODE_VERSION=2.1.311
ARG CODEX_VERSION=0.166.0
ARG NODE_VERSION=22.23.4

# util-linux is setpriv. Node comes from nodejs.org since Claude Code needs 22 and Ubuntu's is 18.
# The last two commands fail the build if npm left a CLI that doesn't run, which it can do without an error.
RUN apt-get update \
	&& apt-get install -y --no-install-recommends ca-certificates tzdata util-linux curl xz-utils \
	&& case "$(dpkg --print-architecture)" in \
		amd64) node_arch=x64 node_sha=1805bcd35e6815559bd2eb97db438d3fdb0eb3a5e6a977b7c1badca76337e9ce ;; \
		arm64) node_arch=arm64 node_sha=6287aa46b6c375d816e63ae66d024fbbfd70404825aabdfdf898a970871d2f4b ;; \
		*) echo "No Node checksum for this architecture" >&2; exit 1 ;; \
	esac \
	&& curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/node-v${NODE_VERSION}-linux-${node_arch}.tar.xz" -o /tmp/node.tar.xz \
	&& echo "${node_sha}  /tmp/node.tar.xz" | sha256sum -c - \
	&& tar -xJf /tmp/node.tar.xz -C /usr/local --strip-components=1 --no-same-owner \
	&& rm /tmp/node.tar.xz \
	&& npm install -g "@anthropic-ai/claude-code@${CLAUDE_CODE_VERSION}" "@openai/codex@${CODEX_VERSION}" \
	&& npm cache clean --force \
	&& rm -rf /var/lib/apt/lists/* \
	&& claude --version \
	&& codex --version

RUN groupadd --system ergo \
	&& useradd --system --gid ergo --home-dir /data --shell /usr/sbin/nologin ergo \
	&& groupadd --system ergo-runner \
	&& useradd --system --gid ergo-runner --home-dir /nonexistent --no-create-home --shell /usr/sbin/nologin ergo-runner \
	&& mkdir -p /data /runs /opt/ergo-cli \
	&& chown ergo:ergo /data /runs /opt/ergo-cli \
	&& chmod 0700 /data \
	&& chmod 0711 /runs \
	&& chmod 0755 /opt/ergo-cli

WORKDIR /app
COPY --from=build /staging /app

# The key file is made by hand, 0600 and owned by ergo:
#   head -c 32 /dev/urandom | base64 > /data/vault.key
ENV ERGO_DATABASE_PATH=/data/ergo.sqlite \
	ERGO_VAULT_KEY_FILE=/data/vault.key \
	ERGO_RUNS_DIRECTORY=/runs \
	ERGO_CLAUDE_PATH=/usr/local/bin/claude \
	ERGO_CODEX_PATH=/usr/local/bin/codex \
	ERGO_CLI_DIRECTORY=/opt/ergo-cli \
	ERGO_CLAUDE_CODE_VERSION=${CLAUDE_CODE_VERSION} \
	ERGO_CODEX_VERSION=${CODEX_VERSION} \
	ERGO_RUNNER_USER=ergo-runner \
	ERGO_RUNNER_PREFIX="/usr/bin/setpriv --reuid=ergo-runner --regid=ergo-runner --clear-groups --inh-caps=-all --ambient-caps=-all --no-new-privs --"

VOLUME /data
EXPOSE 8080

# Root only long enough to drop to ergo, keeping just the three capabilities the runner switch needs
ENTRYPOINT [ \
	"/usr/bin/setpriv", "--reuid=ergo", "--regid=ergo", "--init-groups", \
	"--inh-caps=-all,+setuid,+setgid,+chown", "--ambient-caps=-all,+setuid,+setgid,+chown", \
	"--bounding-set=-all,+setuid,+setgid,+chown", \
	"--", "/app/ErgoServer" \
]
CMD ["serve", "--env", "production", "--hostname", "0.0.0.0", "--port", "8080"]
