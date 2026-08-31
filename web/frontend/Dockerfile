FROM node:22-alpine AS build

ARG VITE_API_URL
ENV VITE_API_URL=$VITE_API_URL

WORKDIR /app

COPY package.json package-lock.json* ./
# @moonfive/auth-client is vendored as a git submodule (vendor/auth-client,
# dist/ committed — no build step) and consumed via a package.json
# "file:./vendor/auth-client" dependency, so it must be present before
# `npm ci` resolves it.
COPY vendor ./vendor
RUN npm ci

COPY . .

RUN npm run build

FROM nginx:alpine

COPY nginx.conf /etc/nginx/templates/default.conf.template
COPY --from=build /app/dist /usr/share/nginx/html

EXPOSE 8080
