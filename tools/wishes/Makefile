# tools/wishes. `make test` is seconds; `make proof` runs the real rmfakecloud
# from the server image (make -C ../../server image) and takes about a minute.
PY := .venv/bin/python
.PHONY: venv test proof emu clean

venv: $(PY)
$(PY): requirements.txt
	python3 -m venv .venv
	$(PY) -m pip install -q -r requirements.txt
	touch $(PY)

test: $(PY)
	$(PY) -m pytest -q -p no:cacheprovider .
	shellcheck test/*.sh

proof: $(PY)
	test/rmfakecloud-proof.sh

emu: $(PY)
	test/emu-scan.sh

clean:
	rm -rf .venv __pycache__
