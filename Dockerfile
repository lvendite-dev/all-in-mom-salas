# Servidor de salas do ALL IN MOM para o Render.com (ou qualquer Docker).
FROM debian:bookworm-slim

RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates wget unzip libfontconfig1 \
 && rm -rf /var/lib/apt/lists/*

# Godot 4.7.2 para Linux (só usado sem tela, com --headless).
RUN wget -q https://github.com/godotengine/godot/releases/download/4.7.2-stable/Godot_v4.7.2-stable_linux.x86_64.zip -O /tmp/godot.zip \
 && unzip -q /tmp/godot.zip -d /tmp \
 && mv /tmp/Godot_v4.7.2-stable_linux.x86_64 /usr/local/bin/godot \
 && chmod +x /usr/local/bin/godot \
 && rm /tmp/godot.zip

WORKDIR /app
COPY project.godot servidor.gd servidor.tscn ./

# Importa o projeto já na montagem, para o servidor ligar mais rápido.
RUN godot --headless --path /app --import || true

# O Render informa a porta pela variável PORT (o servidor lê sozinho).
ENV PORT=10000
EXPOSE 10000
CMD ["godot", "--headless", "--path", "/app"]
