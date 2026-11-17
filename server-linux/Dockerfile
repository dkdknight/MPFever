# The relay (mpfever-relay), NOT the dedicated server: no game in it. See docs/LINUX-RELAY.md, "With Docker".
# Build, from the root of the repository (the relay is built from the launcher's protocol sources too):
#   docker build -f server-linux/Dockerfile -t mpfever-relay .
# Run (the password comes from the environment, not from the command line):
#   docker run -d --name mpfever-relay -p 28090:28090 -e MPFEVER_RELAY_PASSWORD=SECRET mpfever-relay
# x64 and arm64 (Raspberry Pi, ARM servers): docker buildx build --platform linux/amd64,linux/arm64 ...

FROM --platform=$BUILDPLATFORM mcr.microsoft.com/dotnet/sdk:9.0 AS build
ARG TARGETARCH
WORKDIR /src
COPY launcher/Core.cs launcher/RemoteRelay.cs launcher/CheckpointWire.cs launcher/
COPY server-linux/ server-linux/
# (the same self-contained single file as the release archive, for the machine the image runs on)
RUN case "$TARGETARCH" in arm64) rid=linux-arm64 ;; *) rid=linux-x64 ;; esac \
 && dotnet publish server-linux/MPFeverRelay.csproj -c Release -r "$rid" --self-contained -p:PublishSingleFile=true -o /out \
 && mkdir /data

# (no shell, no package manager, not root: user "app", 1654)
FROM mcr.microsoft.com/dotnet/runtime-deps:9.0-noble-chiseled
WORKDIR /app
COPY --from=build /out/mpfever-relay /app/mpfever-relay
# where --checkpoint-dir may point (keeping the session's save): mount a volume here
COPY --from=build --chown=1654:1654 /data /data
VOLUME /data
ENV DOTNET_BUNDLE_EXTRACT_BASE_DIR=/tmp
EXPOSE 28090/tcp
USER 1654
ENTRYPOINT ["/app/mpfever-relay"]
CMD ["--port", "28090"]
