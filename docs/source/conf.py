# Configuration file for the Sphinx documentation builder.
#
# For the full list of built-in configuration values, see the documentation:
# https://www.sphinx-doc.org/en/master/usage/configuration.html

# -- Project information -----------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#project-information

project = 'Agentic Coding Harness'
copyright = '2026, Michael Jansen'
author = 'Michael Jansen'
release = '0.1'

# -- General configuration ---------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#general-configuration

extensions = [
    'sphinx.ext.intersphinx',
    'sphinxcontrib.mermaid',
    'sphinx_copybutton',
    'sphinxext.opengraph',
    'sphinx_adr',
]

templates_path = ['_templates']
exclude_patterns = []

# The sphinx-adr decision log is placed in Furo's right sidebar via
# _templates/page.html (override of the right_sidebar block). See ADR 001.

# -- sphinx-adr ---------------------------------------------------------------
# ADRs live in source/decisions and are rendered via the ``adrlist`` directive.
adr_path = 'decisions'

# -- mermaid -------------------------------------------------------------------
mermaid_version = '11'

# -- opengraph -----------------------------------------------------------------
ogp_site_url = 'https://ferroclass.example/docs/'  # placeholder, no image for now

# -- intersphinx ---------------------------------------------------------------
intersphinx_mapping = {
    'python': ('https://docs.python.org/3', None),
}



# -- Options for HTML output -------------------------------------------------
# https://www.sphinx-doc.org/en/master/usage/configuration.html#options-for-html-output

html_theme = 'furo'
html_static_path = ['_static']
html_css_files = ['custom.css']
