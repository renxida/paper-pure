# tools/wishes. `make test` is seconds; `make proof` runs the real rmfakecloud
# from the server image (make -C ../../server image) and takes about a minute.
# wishes.py is a link to ../../server/wishes/wishes.py: the server image runs
# that file, and Docker can only copy from server/.
PY := .venv/bin/python
.PHONY: venv test proof emu clean

venv: $(PY)
$(PY): requirements.txt ../../server/wishes/requirements.txt
	@python3 -c 'import sys; sys.exit(sys.version_info[:2] != (3, 13) and "tools/wishes needs python3 = 3.13: the pinned wheels are for 3.13, like the server image")'
	python3 -m venv .venv
	$(PY) -m pip install -q --disable-pip-version-check --require-hashes --only-binary=:all: -r requirements.txt
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
