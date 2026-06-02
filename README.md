# cldk-skillset

A collection of agent skills for working with [CodeLLM-DevKit (CLDK)](https://github.com/codellm-devkit) for *extending* and *maintaining* CLDK. This repo gathers reusable agent skills that help developers extend and expand CLDK itself (e.g., adding support for a new language, wiring up SDKs, adding new analyses, etc.).

## Available Skills

### `cldk-language-pack`

This is an end-to-end skill that adds first-class support for a new language to CLDK as a "pack" that helps you bundle the backend analyzer and both SDKs. It scaffolds and wires up:
  - the **backend analyzer**: `codeanalyzer-<lang>` — modeled on [`../codeanalyzer-java`](../codeanalyzer-java) and [`../codeanalyzer-python`](../codeanalyzer-python)
  - the **Python SDK** bindings/APIs
  - the **TypeScript SDK** bindings/APIs

Each skill lives in its own directory with a `SKILL.md` describing when and how to invoke it and all the helpers/references to help build this out.
