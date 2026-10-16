FROM dart:3.13.1 AS build

WORKDIR /src/backend

# Copy the manifests first so dependency resolution remains cacheable and uses
# the repository's committed lockfile.
COPY deckboard_daemon/backend/pubspec.yaml deckboard_daemon/backend/pubspec.lock ./
RUN dart pub get --enforce-lockfile

COPY deckboard_daemon/backend/bin/ ./bin/
COPY deckboard_daemon/backend/lib/ ./lib/
RUN mkdir -p /opt/kdedeck \
    && dart compile exe bin/backend.dart -o /opt/kdedeck/kdedeck_daemon

FROM dart:3.13.1

RUN useradd --create-home --uid 10001 --shell /usr/sbin/nologin kdedeck

WORKDIR /opt/kdedeck/backend

COPY --from=build /opt/kdedeck/kdedeck_daemon /opt/kdedeck/kdedeck_daemon
COPY deckboard_daemon/frontend/ /opt/kdedeck/frontend/
COPY deckboard_daemon/backend/deckboard_config.json /opt/kdedeck/backend/deckboard_config.json

RUN chown -R kdedeck:kdedeck /opt/kdedeck
USER kdedeck

EXPOSE 8484

ENTRYPOINT ["/opt/kdedeck/kdedeck_daemon"]
