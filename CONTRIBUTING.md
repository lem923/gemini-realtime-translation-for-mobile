# Contributing to realtime-translation

Thank you for your interest in contributing to realtime-translation! This document provides guidelines and instructions for contributing.

## Development Setup

### Prerequisites

- Git 2.40+
- Current stable Flutter SDK and bundled Dart SDK once the implementation workspace is added
- Android Studio, Android SDK, and a physical Android device for Phase 1 audio work
- Xcode and a physical iPhone for later iOS adapter work

### Getting Started

```bash
# Clone the repository
git clone <repo-url>
cd realtime-translation

# Phase 0 currently has no runtime dependencies.
# Read README.md, AGENTS.md, and docs/roadmap.md before proposing code.
```

## How to Contribute

### Branch Naming

- `feat/<short-description>` — new features
- `fix/<short-description>` — bug fixes
- `docs/<short-description>` — documentation changes
- `refactor/<short-description>` — code refactoring

### Pull Request Process

1. Fork the repository and create a feature branch
2. Make your changes with clear, descriptive commit messages
3. Add or update tests for your changes
4. Run the checks documented by the package you changed
5. Update documentation if needed
6. Submit a pull request with a description of your changes

### Code Style

- Keep Dart analysis strict and avoid `dynamic` in protocol/audio paths.
- Keep Kotlin and Swift platform integration behind typed Flutter interfaces.
- Keep audio capture, conversion, transport, session state, and playback separate.
- Add tests for state machines, transcript delta assembly, and queue behavior.
- Never include real keys, tokens, audio, or transcripts in fixtures.

### Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/):

```
<type>(<scope>): <description>

[optional body]
```

Types: `feat`, `fix`, `docs`, `style`, `refactor`, `perf`, `test`, `build`, `ci`, `chore`

## Reporting Issues

- Use GitHub Issues to report bugs or request features
- Include steps to reproduce for bug reports
- Search existing issues before creating a new one

## Questions?

Feel free to open an issue with the "question" label.
