#!/usr/bin/env bash
asciidoctor index.adoc -D ../gh-pages/ \
  -a source-highlighter=highlight.js -a icons=font \
  -a stylesheet=stylesheet.css
