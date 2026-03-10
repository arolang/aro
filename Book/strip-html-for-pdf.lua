-- strip-html-for-pdf.lua
-- Remove HTML content from LaTeX/PDF output.
--
-- pandoc 3.9 converts <div style="..."> to a native pandoc Div element
-- and parses SVG <text> content inside it, including \n sequences, which
-- causes xelatex errors like: ! Undefined control sequence. \nWorld
--
-- Three filters are needed:
--   RawBlock  - removes standalone raw HTML blocks
--   RawInline - removes inline HTML tags (e.g. <br>)
--   Div       - removes <div style="..."> diagrams (pandoc 3.9 native Div)

function RawBlock(el)
  if el.format:match("html") then
    return {}
  end
end

function RawInline(el)
  if el.format:match("html") then
    return pandoc.Str("")
  end
end

-- Remove Div elements that originated from HTML <div style="..."> tags.
-- These contain SVG diagrams that cannot be rendered in LaTeX.
-- Legitimate pandoc Divs (from ::: {.class} fences) never have a style attribute.
function Div(el)
  if el.attr.attributes["style"] then
    return {}
  end
end
