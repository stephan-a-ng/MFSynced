# syntax=docker/dockerfile:1
#
#   docker buildx build --secret id=npm_auth_token,env=NODE_AUTH_TOKEN \
#     -t frontend --load .
#
# `npm ci` below resolves @moonfive/auth-client from GitHub Packages (see
# .npmrc) and needs a read:packages token as NODE_AUTH_TOKEN. Passed as a
# BuildKit secret (`--secret ...,env=`, mounted only for that one RUN) rather
# than an ARG/ENV so it never lands in an image layer. Plain `docker build`
# (no buildx) cannot supply this.
#
# NOTE: cloudbuild.yaml (the production build path, `gcr.io/cloud-builders/
# docker`) does not yet pass this secret — see the auth-client-adoption PR
# description for that follow-up.
FROM node:22-alpine AS build

ARG VITE_API_URL
ENV VITE_API_URL=$VITE_API_URL

WORKDIR /app

COPY package.json package-lock.json* .npmrc ./
RUN --mount=type=secret,id=npm_auth_token,env=NODE_AUTH_TOKEN \
    npm ci

COPY . .

RUN npm run build

FROM nginx:alpine

COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 8080
