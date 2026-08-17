FROM node:22-slim

WORKDIR /app

COPY package.json package-lock.json ./
RUN npm ci --omit=dev

COPY tsconfig.json ./
COPY src ./src
COPY resources ./resources

# Pre-downloads Gatling's own runtime bundle (a full GraalVM JDK + Java libs, ~376MB
# measured — see README "Container build") at IMAGE BUILD time instead of at container
# start. GitHub Actions runners are linux/amd64, the same architecture as the target
# cluster's nodes, so the bundle downloaded here is directly usable at runtime — no
# separate cache PVC or runtime download needed, and no risk of paying that cost on
# every trial.
RUN npx gatling build --typescript

COPY docker/entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

ENTRYPOINT ["/entrypoint.sh"]
