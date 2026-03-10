-- strip-html-for-pdf.lua
-- Remove raw HTML blocks from LaTeX/PDF output.
-- SVG diagrams and other HTML content render in the HTML build
-- but are omitted from the PDF rather than causing xelatex errors.
function RawBlock(el)
  if el.format:match("html") then
    return {}
  end
end
