FROM node:22-bookworm-slim
WORKDIR /srv/collectibles
COPY package.json package-lock.json ./
RUN npm ci --omit=dev
COPY src ./src
ENV COLLECTIBLES_PORT=8091
EXPOSE 8091
CMD ["node","src/server.mjs"]
