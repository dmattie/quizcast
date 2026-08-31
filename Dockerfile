FROM rocker/r-ver:4.4.1

# rocker/r-ver points at the Posit binary repo, so these install as prebuilt
# binaries rather than compiling from source. Keeps the build near two minutes.
RUN R -q -e "install.packages(c('shiny','yaml','commonmark','qrcode'), Ncpus = 4)" \
 && R -q -e "stopifnot(all(c('shiny','yaml','commonmark','qrcode') %in% rownames(installed.packages())))"

WORKDIR /srv/quizcast
COPY lib/     lib/
COPY www/     www/
COPY quizzes/ quizzes/
COPY app.R    .

# Container Apps sends traffic to the port named in --target-port.
ENV PORT=8000
EXPOSE 8000

# One process, one replica. All game state lives in this process's memory.
CMD ["R", "-q", "-e", "shiny::runApp('/srv/quizcast', host = '0.0.0.0', port = as.integer(Sys.getenv('PORT', 8000)), launch.browser = FALSE)"]
