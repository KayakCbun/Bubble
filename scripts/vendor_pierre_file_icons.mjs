#!/usr/bin/env node
import { createRequire } from "node:module";
import { mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const require = createRequire(import.meta.url);
const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const pierreDist = "/tmp/pierre-trees/package/dist/builtInIcons.js";
const { getBuiltInSpriteSheet } = require(pierreDist);
const pierreSrc = readFileSync(pierreDist, "utf8");

function extractObjectLiteral(source, name) {
  const start = source.indexOf(`const ${name} = {`);
  if (start < 0) throw new Error(`missing ${name}`);
  let i = source.indexOf("{", start);
  let depth = 0;
  for (let j = i; j < source.length; j += 1) {
    if (source[j] === "{") depth += 1;
    if (source[j] === "}") {
      depth -= 1;
      if (depth === 0) {
        const jsonish = source
          .slice(i, j + 1)
          .replace(/(\n\s*)([A-Za-z_][\w.-]*):/g, '$1"$2":')
          .replace(/,(\s*})/g, "$1");
        return JSON.parse(jsonish);
      }
    }
  }
  throw new Error(`unclosed ${name}`);
}

const nameTokens = extractObjectLiteral(pierreSrc, "BUILT_IN_FILE_NAME_TOKENS");
const extensionTokens = extractObjectLiteral(pierreSrc, "BUILT_IN_FILE_EXTENSION_TOKENS");
const completeOverrides = extractObjectLiteral(pierreSrc, "COMPLETE_EXTENSION_OVERRIDES");

const t3Extras = readFileSync("/tmp/t3code-src/apps/web/src/pierre-icons.ts", "utf8");
const spriteMatch = t3Extras.match(/const T3_FILE_ICON_SPRITE = `\n([\s\S]*?)`;/);
if (!spriteMatch) throw new Error("missing T3_FILE_ICON_SPRITE");
const t3SpriteInner = spriteMatch[1]
  .replace(/^<svg[^>]*>\n/, "")
  .replace(/<\/svg>\s*$/, "")
  .trim();

const completeSheet = getBuiltInSpriteSheet("complete").replace(
  "</svg>",
  `\n  ${t3SpriteInner}\n</svg>`,
);

const t3ByFileName = {
  "package.json": "t3-file-icon-package-json",
  "tsconfig.json": "t3-file-icon-tsconfig",
  "agents.md": "t3-file-icon-agents",
  "claude.md": "t3-file-icon-claude",
  "readme.md": "t3-file-icon-readme",
  "pnpm-lock.yaml": "t3-file-icon-pnpm",
  "pnpm-workspace.yaml": "t3-file-icon-pnpm",
};

const lightColors = {
  astro: "A631BE",
  babel: "D5A910",
  bash: "199F43",
  biome: "1A85D4",
  bootstrap: "693ACF",
  browserslist: "D5A910",
  bun: "594C5B",
  c: "1A85D4",
  claude: "D47628",
  cpp: "1A85D4",
  css: "693ACF",
  database: "A631BE",
  default: "84848A",
  docker: "1A85D4",
  eslint: "693ACF",
  font: "84848A",
  git: "D5512F",
  go: "1CA1C7",
  graphql: "D32A61",
  html: "D47628",
  image: "D32A61",
  javascript: "D5A910",
  json: "D47628",
  markdown: "199F43",
  mcp: "17A5AF",
  nextjs: "84848A",
  npm: "D52C36",
  oxc: "1CA1C7",
  postcss: "D52C36",
  prettier: "17A5AF",
  python: "1A85D4",
  react: "1CA1C7",
  ruby: "D52C36",
  rust: "D47628",
  sass: "D32A61",
  stylelint: "84848A",
  svelte: "D52C36",
  svg: "D47628",
  svgo: "199F43",
  swift: "D47628",
  table: "17A5AF",
  tailwind: "1CA1C7",
  terraform: "693ACF",
  text: "84848A",
  typescript: "1A85D4",
  vite: "A631BE",
  vscode: "1A85D4",
  vue: "199F43",
  wasm: "693ACF",
  webpack: "1A85D4",
  yml: "D52C36",
  zig: "D47628",
  zip: "D47628",
};

function swiftDict(entries, valueQuoted = true) {
  const lines = Object.entries(entries)
    .sort(([a], [b]) => a.localeCompare(b))
    .map(([k, v]) => {
      const key = JSON.stringify(k);
      const val = valueQuoted ? JSON.stringify(v) : v;
      return `        ${key}: ${val}`;
    });
  return `[\n${lines.join(",\n")}\n    ]`;
}

const swift = `import Foundation

/// File-type icons from Pierre Trees complete sprite (Apache-2.0), plus T3
/// filename extras adapted from vscode-icons as used by T3 Code.
enum PierreFileIconCatalog {
    struct Resolution: Equatable {
        var symbolID: String
        var token: String
        var tints: Bool
    }

    static let nameTokens: [String: String] = ${swiftDict(nameTokens)}

    static let extraNameSymbols: [String: String] = ${swiftDict(t3ByFileName)}

    static let extensionTokens: [String: String] = ${swiftDict(extensionTokens)}

    static let completeOverrides: [String: String] = ${swiftDict(completeOverrides)}

    static let lightColors: [String: String] = ${swiftDict(lightColors)}

    static func resolution(for path: String) -> Resolution {
        let fileName = (path as NSString).lastPathComponent.lowercased()
        if let symbol = extraNameSymbols[fileName] {
            return Resolution(symbolID: symbol, token: "default", tints: false)
        }
        if let token = nameTokens[fileName] {
            return Resolution(symbolID: "file-tree-builtin-\\(token)", token: token, tints: true)
        }
        for ext in extensionCandidates(fileName) {
            if let token = completeOverrides[ext] ?? extensionTokens[ext] {
                return Resolution(symbolID: "file-tree-builtin-\\(token)", token: token, tints: true)
            }
        }
        return Resolution(symbolID: "file-tree-builtin-default", token: "default", tints: true)
    }

    static func extensionCandidates(_ fileName: String) -> [String] {
        let segments = fileName.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard segments.count > 1 else { return [] }
        var result: [String] = []
        for index in 1..<segments.count {
            result.append(segments[index...].joined(separator: "."))
        }
        return result
    }

    static func lightColorHex(for token: String) -> String {
        lightColors[token] ?? lightColors["default"] ?? "84848A"
    }

    static let spriteXML: String = #"""
${completeSheet}
"""#
}
`;

const catalogPath = join(root, "Sources/Bubble/PierreFileIconCatalog.swift");
writeFileSync(catalogPath, swift);
const resDir = join(root, "Resources/FileIcons");
mkdirSync(resDir, { recursive: true });
writeFileSync(join(resDir, "pierre-complete.svg"), completeSheet);
writeFileSync(
  join(resDir, "NOTICE.md"),
  `# File icons

The colored file-type glyphs in \`pierre-complete.svg\` come from
[\`@pierre/trees\`](https://www.npmjs.com/package/@pierre/trees) 1.0.0-beta.4
(Apache License 2.0).

A few exact-filename symbols (package.json, tsconfig, AGENTS.md, CLAUDE.md,
README.md, pnpm) are the extras T3 Code ships in \`pierre-icons.ts\`, adapted
from vscode-icons.

See \`@pierre/trees\` LICENSE.md (Apache-2.0).
`,
);
console.log("wrote", catalogPath);
console.log("sprite bytes", completeSheet.length);
