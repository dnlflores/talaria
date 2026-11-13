import Foundation

/// Which company's logo a model or a provider shows in the model chooser and the composer.
/// Names match the `logo-<name>` images the app carries (`scripts/import-logos.mjs`).
public enum ModelBrand {
  /// The logo of the company that made a model: Claude for `claude-…` and `anthropic/…`, OpenAI
  /// for GPT, Qwen for a local `Qwen3.6-…` file. Falls back to the provider's logo, then nil.
  public static func logo(model: String, provider: String = "") -> String? {
    if let made = maker(of: model) { return made }
    return logo(provider: provider)
  }

  /// The logo of a provider: the company behind the account or service the model runs through.
  public static func logo(provider: String) -> String? {
    let slug = provider.lowercased()
    guard !slug.isEmpty else { return nil }
    if let exact = providers[slug] { return exact }
    // Variants such as `openai-codex`, `xai-grok-oauth`, `antigravity-agy`, `google-gemini-cli`.
    for (prefix, logo) in providerPrefixes where slug.hasPrefix(prefix) { return logo }
    return nil
  }

  /// Providers that run models on the Mac itself, shown with a computer rather than a logo.
  public static func isLocal(provider: String) -> Bool {
    ["llamacpp", "llama.cpp", "local", "custom", "vllm", "mlx"].contains(provider.lowercased())
  }

  private static func maker(of model: String) -> String? {
    let id = model.lowercased()
    guard !id.isEmpty else { return nil }
    let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
    let name = parts.last ?? id
    for (prefix, logo) in families where name.hasPrefix(prefix) { return logo }
    if parts.count == 2, let vendor = vendors[parts[0]] { return vendor }
    return nil
  }

  /// A model's name as it starts, after any `vendor/` prefix. Longer prefixes first where one
  /// contains another (`gpt-oss` before `gpt`, `gemma` before `gem…`).
  private static let families: [(String, String)] = [
    ("claude", "claude"),
    ("gpt", "openai"), ("chatgpt", "openai"), ("codex", "openai"), ("o1", "openai"), ("o3", "openai"),
    ("o4", "openai"), ("davinci", "openai"),
    ("gemini", "gemini"), ("gemma", "gemma"),
    ("grok", "grok"),
    ("deepseek", "deepseek"),
    ("qwen", "qwen"), ("qwq", "qwen"), ("qvq", "qwen"),
    ("kimi", "kimi"), ("moonshot", "moonshot"),
    ("glm", "zai"), ("chatglm", "zai"),
    ("minimax", "minimax"), ("abab", "minimax"),
    ("llama", "meta"), ("meta-llama", "meta"),
    ("mistral", "mistral"), ("mixtral", "mistral"), ("codestral", "mistral"), ("devstral", "mistral"),
    ("magistral", "mistral"), ("ministral", "mistral"), ("pixtral", "mistral"),
    ("hermes", "nousresearch"), ("nous", "nousresearch"),
    ("nemotron", "nvidia"),
    ("command", "cohere"), ("aya", "cohere"),
    ("sonar", "perplexity"),
    ("step-", "stepfun"),
    ("doubao", "bytedance"), ("seed-", "bytedance"),
    ("ernie", "wenxin"),
    ("nova-", "aws"),
    ("jamba", "ai21"),
  ]

  /// The `vendor/` prefix aggregators put before a model's name.
  private static let vendors: [String: String] = [
    "anthropic": "claude", "openai": "openai", "google": "gemini", "x-ai": "grok", "xai": "grok",
    "deepseek": "deepseek", "qwen": "qwen", "moonshotai": "kimi", "z-ai": "zai", "zai-org": "zai",
    "thudm": "zai", "minimax": "minimax", "meta-llama": "meta", "meta": "meta", "mistralai": "mistral",
    "nousresearch": "nousresearch", "nvidia": "nvidia", "cohere": "cohere", "perplexity": "perplexity",
    "stepfun-ai": "stepfun", "bytedance": "bytedance", "bytedance-seed": "bytedance", "baidu": "wenxin",
    "amazon": "aws", "ai21": "ai21", "inflection": "inflection",
  ]

  private static let providers: [String: String] = [
    "nous": "nousresearch", "anthropic": "anthropic", "claude": "claude", "openai": "openai",
    "gemini": "gemini", "google": "google", "vertex": "gemini", "openrouter": "openrouter",
    "deepseek": "deepseek", "zai": "zai", "kimi": "kimi", "moonshot": "moonshot", "minimax": "minimax",
    "mistral": "mistral", "groq": "groq", "together": "together", "fireworks": "fireworks",
    "cerebras": "cerebras", "huggingface": "huggingface", "nvidia": "nvidia", "ollama": "ollama",
    "lmstudio": "lmstudio", "copilot": "githubcopilot", "azure": "azure", "bedrock": "bedrock",
    "cohere": "cohere", "perplexity": "perplexity", "qwen": "qwen", "alibaba": "qwen", "xai": "xai",
  ]

  private static let providerPrefixes: [(String, String)] = [
    ("openai", "openai"), ("anthropic", "anthropic"), ("claude", "claude"), ("xai", "xai"), ("grok", "xai"),
    ("antigravity", "antigravity"), ("google", "google"), ("gemini", "gemini"), ("github", "githubcopilot"),
    ("copilot", "githubcopilot"), ("nous", "nousresearch"), ("kimi", "kimi"), ("moonshot", "moonshot"),
    ("qwen", "qwen"), ("zai", "zai"), ("minimax", "minimax"), ("mistral", "mistral"), ("azure", "azure"),
    ("aws", "bedrock"), ("bedrock", "bedrock"), ("huggingface", "huggingface"), ("hf", "huggingface"),
  ]
}
