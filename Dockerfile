ARG HUGO_VERSION=0.79.1

FROM peaceiris/hugo:v${HUGO_VERSION}-full

COPY . /src

RUN chown -R 1000 /src

USER 1000

WORKDIR /src

RUN hugo -D
