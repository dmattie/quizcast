# Quizcast. Run `make` for the list.
.PHONY: help deps check test run image deploy clean
PORT ?= 8000

help:
	@echo "Quizcast targets:"
	@grep -E '^[a-z-]+:.*##' $(MAKEFILE_LIST) | sed -E 's/:.*## /  --  /'

deps:  ## install the four R packages the app needs
	Rscript -e "install.packages(c('shiny','yaml','commonmark','qrcode'))"

check:  ## parse every R file, a fast syntax gate
	Rscript -e "for (f in c('app.R', list.files(c('lib','tests'), '[.]R$$', full.names=TRUE))) { invisible(parse(f)); cat('  parsed', f, '\n') }"

test:  ## run the full test suite (exits non-zero on failure)
	Rscript tests/run.R

run:  ## serve locally with dev keys
	@echo "  students   http://localhost:$(PORT)"
	@echo "  projector  http://localhost:$(PORT)/?role=present&key=dev-screen"
	@echo "  host       http://localhost:$(PORT)/?role=admin&key=dev-admin"
	@QUIZCAST_ADMIN_KEY=dev-admin QUIZCAST_PRESENT_KEY=dev-screen \
	  Rscript -e "shiny::runApp('.', host='0.0.0.0', port=$(PORT), launch.browser=FALSE)"

image:  ## build the container locally
	docker build -t quizcast:dev .

deploy:  ## create or update the Azure deployment
	./deploy.sh

clean:
	rm -rf .Rproj.user *.Rcheck
