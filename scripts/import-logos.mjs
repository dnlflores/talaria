// Copies the provider and model logos the model chooser shows from Lobe Icons
// (@lobehub/icons-static-svg, MIT) into the asset catalog as template vector images.
//
//   npm pack @lobehub/icons-static-svg && tar xzf lobehub-icons-static-svg-*.tgz
//   node scripts/import-logos.mjs package/icons
//
// Only the monochrome versions are used: the app tints them with the palette, so they follow
// light and dark mode. `ModelBrand` in HermesKit decides which logo a model or provider gets;
// keep the two lists in step.
import { mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join } from "node:path";

const source = process.argv[2];
if (!source) {
  console.error("usage: node scripts/import-logos.mjs <lobe icons folder>");
  process.exit(1);
}

export const logos = [
  "ai21", "anthropic", "antigravity", "aws", "azure", "bedrock", "bytedance", "cerebras", "claude",
  "cohere", "deepseek", "fireworks", "gemini", "gemma", "githubcopilot", "google", "grok", "groq",
  "huggingface", "inflection", "kimi", "lmstudio", "meta", "minimax", "mistral", "moonshot",
  "nousresearch", "nvidia", "ollama", "openai", "openrouter", "perplexity", "qwen", "stepfun",
  "together", "wenxin", "xai", "zai",
];

const folder = new URL("../Talaria/Resources/Assets.xcassets/Logos/", import.meta.url).pathname;
rmSync(folder, { recursive: true, force: true });
mkdirSync(folder, { recursive: true });
writeFileSync(join(folder, "Contents.json"), JSON.stringify({ info: { author: "xcode", version: 1 } }, null, 2) + "\n");

for (const name of logos) {
  let svg = readFileSync(join(source, `${name}.svg`), "utf8");
  // CoreSVG wants plain sizes and colors: no em units, no currentColor, no CSS, no title.
  svg = svg
    .replace(/\s(width|height)="1em"/g, ' $1="24"')
    .replace(/\sstyle="[^"]*"/g, "")
    .replace(/currentColor/g, "#000000")
    .replace(/<title>[^<]*<\/title>/g, "");
  const set = join(folder, `logo-${name}.imageset`);
  mkdirSync(set, { recursive: true });
  writeFileSync(join(set, `${name}.svg`), svg + "\n");
  writeFileSync(
    join(set, "Contents.json"),
    JSON.stringify(
      {
        images: [{ filename: `${name}.svg`, idiom: "universal" }],
        info: { author: "xcode", version: 1 },
        properties: { "preserves-vector-representation": true, "template-rendering-intent": "template" },
      },
      null,
      2,
    ) + "\n",
  );
}
console.log(`wrote ${logos.length} logos to ${folder}`);
