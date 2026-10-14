FROM node:22-alpine AS build
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build
ARG GIT_SHA=unknown
RUN SHORT="$(printf '%s' "$GIT_SHA" | cut -c1-7)" \
  && VERSION="$(node -p "require('./package.json').version")" \
  && printf '{"webSha":"%s","version":"%s"}\n' "$SHORT" "$VERSION" > dist/version.json

FROM nginx:alpine
COPY nginx/default.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/dist /usr/share/nginx/html
EXPOSE 8080
