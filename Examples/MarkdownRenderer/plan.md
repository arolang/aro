# Build a Markdown processing demo using a Python plugin

Create an ARO application that uses custom Markdown actions provided by a Python plugin with the `Markdown` handle.

- `main.aro` -- The `Application-Start` feature set. Create sample Markdown content as a string with headers, bold/italic text, and links. Use three custom actions:
  1. `Markdown.ToHTML the <html-result> from the <markdown>` -- Convert to HTML, extract and log the HTML.
  2. `Markdown.ExtractHeadings the <headings-result> from the <markdown>` -- Extract headings, log the count.
  3. `Markdown.WordCount the <stats> from the <markdown>` -- Count words, log the word count.

- `Plugins/plugin-python-markdown/plugin.yaml` -- Plugin manifest with name `plugin-python-markdown`, handle `Markdown`, providing a `python-plugin` type with Python 3.9 minimum version and requirements.txt.
