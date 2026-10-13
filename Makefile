SHELL := /bin/bash

.PHONY: help submodules

help:
	@echo 'make submodules  # update git submodules (Clash.Meta core sources)'
	@echo ''
	@echo 'The Go core and Rust helper build automatically through the setup build'
	@echo 'hook during flutter build.'

submodules:
	git submodule update --init --recursive
