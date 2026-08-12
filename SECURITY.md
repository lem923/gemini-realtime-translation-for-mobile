# Security Policy for realtime-translation

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| Unreleased | :white_check_mark: |

## Reporting a Vulnerability

**Do not report security vulnerabilities through public GitHub issues.**

Instead, please report them via:

- **GitHub Security Advisories**: Use the [Security Advisories](../../security/advisories/new) feature to privately report a vulnerability.
- **GitHub Security Advisories** is the only configured reporting channel until a dedicated security contact is published.

## Secret-handling requirements

- The user supplies and owns the Gemini API key; the project does not operate a key-storage backend.
- Keys are entered at runtime, kept in memory by default, and sent only to Google's Gemini endpoint.
- A future “remember key” option must be opt-in, local-only, and display the browser-storage risk clearly.
- Audio, transcripts, and keys must not be logged by default.
- Example environment files must contain names and placeholders only.

### What to Include

- Description of the vulnerability
- Steps to reproduce
- Potential impact
- Suggested fix (if any)

### Response Timeline

- **Acknowledgment**: Within 48 hours
- **Initial Assessment**: Within 5 business days
- **Status Updates**: Weekly until resolved

### Disclosure Policy

- Vulnerabilities will be disclosed after a fix is released
- We follow [responsible disclosure](https://en.wikipedia.org/wiki/Responsible_disclosure) practices
- Credit will be given to reporters (unless anonymity is requested)

Thank you for helping keep realtime-translation secure.
