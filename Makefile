# Comandi utili. `make test`, `make rulecheck` e `make e2e` funzionano anche
# senza Xcode (bastano i Command Line Tools).

CLT_DEV := /Library/Developer/CommandLineTools/Library/Developer
# Con i soli Command Line Tools, Swift Testing va indicato a mano.
TEST_FLAGS := $(if $(findstring CommandLineTools,$(shell xcode-select -p 2>/dev/null)),\
	-Xswiftc -F -Xswiftc $(CLT_DEV)/Frameworks -Xlinker -F -Xlinker $(CLT_DEV)/Frameworks \
	-Xlinker -rpath -Xlinker $(CLT_DEV)/Frameworks -Xlinker -rpath -Xlinker $(CLT_DEV)/usr/lib,)
RULECHECK_DIR := $(CURDIR)/.rulecheck

.PHONY: help project test rulecheck e2e icon screenshots

help:
	@echo "make project      rigenera Scudo.xcodeproj da project.yml (XcodeGen)"
	@echo "make test         test del motore (ScudoKit)"
	@echo "make rulecheck    scarica le liste reali, converte, compila con WebKit"
	@echo "make e2e          test di blocco in una WKWebView (dopo rulecheck)"
	@echo "make icon         rigenera l'icona dell'app e quella del sito"
	@echo "make screenshots  adatta gli screenshot in Screenshots/ ad App Store Connect"

project:
	xcodegen generate

test:
	cd Packages/ScudoKit && swift test $(TEST_FLAGS)

rulecheck:
	cd Tools/RuleCheck && swift run -c release rulecheck update --dir "$(RULECHECK_DIR)"

e2e: rulecheck
	cd Tools/RuleCheck && swift run -c release rulecheck e2e --dir "$(RULECHECK_DIR)"

icon:
	swift Tools/make-icon.swift App/Assets.xcassets/AppIcon.appiconset/AppIcon.png 1024
	sips -Z 512 App/Assets.xcassets/AppIcon.appiconset/AppIcon.png --out docs/icon.png

screenshots:
	Tools/resize-screenshots.sh Screenshots
