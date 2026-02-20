<?xml version="1.0" encoding="utf-8"?>
<xsl:stylesheet version="3.0" xmlns:xsl="http://www.w3.org/1999/XSL/Transform"
  xmlns:atom="http://www.w3.org/2005/Atom" xmlns:dc="http://purl.org/dc/elements/1.1/">
  <xsl:output method="html" version="1.0" encoding="UTF-8" indent="yes"/>
  <xsl:template match="/">
    <html xmlns="http://www.w3.org/1999/xhtml" lang="en">
      <head>
        <meta charset="utf-8"/>
        <meta name="viewport" content="width=device-width, initial-scale=1"/>
        <title><xsl:value-of select="/rss/channel/title"/> — RSS Feed</title>
        <style>
          @import url('https://fonts.googleapis.com/css2?family=Space+Grotesk:wght@400;600;700&amp;family=Inter:wght@400;500&amp;display=swap');
          *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
          body {
            background: hsl(0,0%,4%);
            color: hsl(0,0%,90%);
            font-family: 'Inter', sans-serif;
            -webkit-font-smoothing: antialiased;
            padding: 0 1.5rem;
          }
          h1, h2, h3 { font-family: 'Space Grotesk', sans-serif; }
          header {
            border-bottom: 1px solid hsl(0,0%,16%);
            padding: 1.25rem 0;
            max-width: 800px;
            margin: 0 auto;
            display: flex;
            align-items: center;
            justify-content: space-between;
          }
          .logo { display: flex; align-items: center; gap: 0.6rem; text-decoration: none; color: inherit; }
          .logo-name { font-family: 'Space Grotesk', sans-serif; font-weight: 700; font-size: 1rem; }
          .logo-sep { color: hsl(0,0%,25%); }
          .logo-sub { color: hsl(0,0%,50%); font-size: 0.9rem; }
          .badge {
            font-size: 0.7rem;
            font-weight: 600;
            padding: 0.2rem 0.55rem;
            border: 1px solid hsl(0,0%,20%);
            border-radius: 4px;
            color: hsl(0,0%,55%);
            background: hsl(0,0%,10%);
            text-transform: uppercase;
            letter-spacing: 0.05em;
          }
          main { max-width: 800px; margin: 0 auto; padding: 2.5rem 0 4rem; }
          .intro {
            background: hsl(0,0%,8%);
            border: 1px solid hsl(0,0%,14%);
            border-radius: 8px;
            padding: 1.25rem 1.5rem;
            margin-bottom: 2.5rem;
          }
          .intro p { color: hsl(0,0%,55%); font-size: 0.875rem; line-height: 1.6; margin-top: 0.4rem; }
          .intro a { color: hsl(0,0%,75%); }
          .posts-label {
            font-size: 0.7rem;
            font-weight: 600;
            letter-spacing: 0.08em;
            text-transform: uppercase;
            color: hsl(0,0%,40%);
            margin-bottom: 1rem;
          }
          .post {
            padding: 1.25rem 0;
            border-bottom: 1px solid hsl(0,0%,12%);
          }
          .post:last-child { border-bottom: none; }
          .post-title a {
            font-family: 'Space Grotesk', sans-serif;
            font-weight: 600;
            font-size: 1rem;
            color: hsl(0,0%,90%);
            text-decoration: none;
          }
          .post-title a:hover { color: #fff; }
          .post-meta {
            display: flex;
            align-items: center;
            gap: 0.6rem;
            margin-top: 0.35rem;
          }
          .post-date { font-size: 0.8rem; color: hsl(0,0%,45%); }
          .post-desc { font-size: 0.875rem; color: hsl(0,0%,55%); margin-top: 0.4rem; line-height: 1.6; }
        </style>
      </head>
      <body>
        <header>
          <div class="logo">
            <span class="logo-name">Aethos Tech</span>
            <span class="logo-sep">/</span>
            <span class="logo-sub">Blog</span>
          </div>
          <span class="badge">RSS Feed</span>
        </header>
        <main>
          <div class="intro">
            <h2 style="font-size:1rem;color:hsl(0,0%,80%);"><xsl:value-of select="/rss/channel/title"/></h2>
            <p><xsl:value-of select="/rss/channel/description"/></p>
            <p style="margin-top:0.6rem;">
              Subscribe by copying this URL into your RSS reader:
              <a><xsl:attribute name="href"><xsl:value-of select="/rss/channel/link"/>/rss.xml</xsl:attribute>
                <xsl:value-of select="/rss/channel/link"/>/rss.xml</a>
            </p>
          </div>
          <div class="posts-label">Latest posts</div>
          <xsl:for-each select="/rss/channel/item">
            <div class="post">
              <div class="post-title">
                <a>
                  <xsl:attribute name="href"><xsl:value-of select="link"/></xsl:attribute>
                  <xsl:value-of select="title"/>
                </a>
              </div>
              <div class="post-meta">
                <span class="post-date"><xsl:value-of select="pubDate"/></span>
              </div>
              <p class="post-desc"><xsl:value-of select="description"/></p>
            </div>
          </xsl:for-each>
        </main>
      </body>
    </html>
  </xsl:template>
</xsl:stylesheet>
