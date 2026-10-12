// SPDX-License-Identifier: Apache-2.0

// The site's shared copy (header, footer, 404, docs chrome). English only.
// The landing page's copy is in landing.ts. Components never hold copy.

export const strings = {
  site: {
    name: "VMPane",
    title: "VMPane: macOS, Linux and Windows 11 virtual machines on your Mac",
    description:
      "VMPane runs macOS, Linux and Windows 11 on Arm in native Mac windows, and lets AI agents use a VM within limits you set. Free and open source, for Macs with Apple silicon.",
  },
  llms: {
    summary:
      "VMPane is a native macOS app that runs macOS, Linux and Windows 11 on Arm virtual machines on Apple silicon Macs. macOS and Linux run on Apple's Virtualization framework; Windows runs on QEMU with Hypervisor.framework, a software TPM and Secure Boot. A built-in MCP server (`vmpane mcp`) lets AI agents use a VM at one of five access levels; every VM starts at Off.",
    details: [
      "Status: pre-alpha; public betas come first. Macs with Apple silicon, macOS 15 or later. Open source under the Apache 2.0 license: https://github.com/nhtera/vmpane",
    ],
  },
  ogCard: {
    headline: "Three systems. One Mac.",
    sub: "macOS, Linux and Windows 11 in native Mac windows.",
  },
  nav: {
    skip: "Skip to content",
    label: "Site",
    home: "VMPane home",
    menu: "Menu",
    links: [
      { label: "Features", hash: "guests" },
      { label: "AI agents", hash: "agents" },
      { label: "FAQ", hash: "faq" },
    ],
    docs: "Docs",
    github: "GitHub",
    cta: "Download for Mac",
  },
  theme: {
    toDark: "Switch to dark theme",
    toLight: "Switch to light theme",
  },
  footer: {
    product: {
      title: "Product",
      links: [
        { label: "Features", hash: "guests" },
        { label: "AI agents", hash: "agents" },
        { label: "FAQ", hash: "faq" },
      ],
      download: "Download",
    },
    docs: {
      title: "Docs",
      links: [
        { label: "Get started", slug: "overview" },
        { label: "vmpane commands", slug: "cli" },
        { label: "Security model", slug: "security-model" },
      ],
    },
    project: {
      title: "Project",
      source: "Source code",
      security: { label: "Security policy", slug: "security", file: "SECURITY.md" },
      llms: "llms.txt",
    },
    legal: ["Apache-2.0", "Not affiliated with Apple or Microsoft."],
  },
  notFound: {
    metaTitle: "Page not found · VMPane",
    code: "404",
    title: "This page isn't here",
    body: "The link may be old, or the page moved. The docs and the home page are a good place to start.",
    home: "Go to the home page",
    docs: "Read the docs",
  },
  docs: {
    titleSuffix: " · VMPane docs",
    navLabel: "Docs",
    menu: "Docs menu",
    search: "Search docs",
    searchShortcut: "⌘K",
    searchEmpty: (q: string) => `No page matches “${q}”. Try a shorter word.`,
    searchLoading: "Loading…",
    searchError: "Search could not load. Try again.",
    toc: "On this page",
    pager: "Previous and next page",
    previous: "Previous",
    next: "Next",
    edit: "Edit this page on GitHub",
    lastUpdated: "Last updated",
    copy: "Copy",
    copied: "Copied",
    selected: "Selected",
    codeLabel: "Code",
    tableLabel: "Table",
    indexSections: "Sections",
  },
} as const;
