# Doc Combiner

Doc Combiner is a local-first macOS utility for combining multiple Word `.docx` files into one `.docx` file.

Drop two or more Word documents onto the app, choose an output location if needed, and combine them in order. The combiner starts from the first document, appends the body content from the rest, and carries over common document parts such as embedded media, hyperlinks, missing styles, and list numbering.

## Run the CLI

```sh
swift run doc-combiner First.docx Second.docx --output Combined.docx
```

Use `--no-page-breaks` to append documents continuously instead of starting each added document on a new page.

## Run the macOS App

```sh
./scripts/run-app.sh
```

The helper script builds the Swift package, wraps the executable in a local `.app` bundle under `.build/debug`, and opens it.

## Development

Run tests with:

```sh
swift test
```

## Notes

Doc Combiner edits the Office Open XML package directly. It is intended for normal body content, paragraphs, tables, embedded media, hyperlinks, styles, and numbered lists. Advanced Word features that depend on cross-document global parts, such as tracked changes, comments, footnotes, custom XML, or complex chart dependencies, may need review in Word after combining.
