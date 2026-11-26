# Renders assets/console-{dark,light}.svg from profile.yml + the GitHub GraphQL API.
# Zero gems, zero third-party services: run by .github/workflows/render.yml.
#
#   GH_TOKEN=$(gh auth token) ruby src/render.rb

require "net/http"
require "json"
require "yaml"
require "date"

ROOT    = File.expand_path("..", __dir__)
PROFILE = YAML.load_file(File.join(ROOT, "profile.yml"))
TOKEN   = ENV["GH_TOKEN"] || ENV["GITHUB_TOKEN"] or abort("Set GH_TOKEN or GITHUB_TOKEN")

# ---------------------------------------------------------------- data
QUERY = <<~GQL
  query($login: String!) {
    user(login: $login) {
      repositories(ownerAffiliations: OWNER, isFork: false, privacy: PUBLIC, first: 100) {
        totalCount
        nodes { stargazerCount primaryLanguage { name } }
      }
      contributionsCollection {
        contributionCalendar {
          totalContributions
          weeks { contributionDays { date contributionCount contributionLevel } }
        }
      }
    }
  }
GQL

def fetch(login)
  uri = URI("https://api.github.com/graphql")
  req = Net::HTTP::Post.new(uri, "Authorization" => "bearer #{TOKEN}", "Content-Type" => "application/json")
  req.body = { query: QUERY, variables: { login: login } }.to_json
  res = Net::HTTP.start(uri.host, uri.port, use_ssl: true) { |http| http.request(req) }
  body = JSON.parse(res.body)
  abort("GraphQL error: #{body["errors"] || res.code}") if body["errors"] || !res.is_a?(Net::HTTPSuccess)
  body.dig("data", "user")
end

user  = fetch(PROFILE["login"])
repos = user["repositories"]
cal   = user.dig("contributionsCollection", "contributionCalendar")
DAYS  = cal["weeks"].flat_map { |w| w["contributionDays"] }.last(64)
top   = repos["nodes"].filter_map { |r| r.dig("primaryLanguage", "name") }.tally.max_by(&:last)&.first

STATS = {
  repos: repos["totalCount"],
  stars: repos["nodes"].sum { |r| r["stargazerCount"] },
  contributions_1y: cal["totalContributions"],
  top: top
}

# ---------------------------------------------------------------- script
inspect_stats = "{ " + STATS.map { |k, v| "#{k}: #{v.is_a?(String) ? %("#{v}") : v}" }.join(", ") + " }"
pad = " " * "=> #<Developer ".length

SCRIPT = [
  [:shell, "$ bin/rails console"],
  [:muted, "Loading development environment"],
  [:cmd,   %(me = Developer.find_by(github: "#{PROFILE["login"]}"))],
  [:out,   %(=> #<Developer name: "#{PROFILE["name"]}",)],
  [:out,   %(#{pad}role: "#{PROFILE["role"]}", city: "#{PROFILE["city"]}">)],
  [:cmd,   "me.stack"],
  [:out,   "=> [" + PROFILE["stack"].map { |s| ":#{s}" }.join(", ") + "]"],
  [:cmd,   "me.stats"],
  [:out,   "=> #{inspect_stats}"],
  [:cmd,   "me.now"],
  [:out,   %(=> "#{PROFILE["now"]}")],
  [:cmd,   "me.motto"],
  [:out,   %(=> "#{PROFILE["motto"]}")],
  [:end,   ""]
]

# ---------------------------------------------------------------- themes
THEMES = {
  "dark" => {
    bg: "#0d1117", bar: "#161b22", border: "#30363d", text: "#e6edf3", muted: "#8b949e",
    prompt: "#ff7b72", const: "#7ee787", sym: "#79c0ff", str: "#ffd75e", num: "#ffa657", key: "#d2a8ff",
    sq: ["#1d3557", "#142844"], lvl: ["#c9a800", "#dcb900", "#efc900", "#ffd500"], piece: "#e6edf3"
  },
  "light" => {
    bg: "#ffffff", bar: "#f6f8fa", border: "#d0d7de", text: "#1f2328", muted: "#656d76",
    prompt: "#cf222e", const: "#116329", sym: "#0550ae", str: "#9a6700", num: "#953800", key: "#8250df",
    sq: ["#e3ecf8", "#c6d7ef"], lvl: ["#e0ad00", "#e8b700", "#f0c100", "#f7ca00"], piece: "#0057b7"
  }
}

LEVELS = %w[FIRST_QUARTILE SECOND_QUARTILE THIRD_QUARTILE FOURTH_QUARTILE]

W, H         = 860, 372
SQ           = 30
BOARD_X      = 40
BOARD_Y      = 82
CON_X        = 318
CON_Y        = 76
LINE_H       = 20
CHAR_W       = 7.85   # ~0.6em at 13px; only drives typing speed, not layout
TYPE_SPEED   = 0.035  # s per char
FONT         = "ui-monospace, SFMono-Regular, 'SF Mono', Menlo, Consolas, 'Liberation Mono', monospace"
KNIGHT       = "♞"

def esc(s) = s.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")

# Tiny Ruby-ish highlighter -> <tspan>s
TOKEN_RE = /("(?:[^"\\]|\\.)*")|(:[a-z_]\w*)|(\b[a-z_]\w*:(?=\s))|(\b\d+\b)|(\b[A-Z]\w*)|(=>|>>|#<|\$)|([^"]+?(?=["]|:[a-z_]|\b[a-z_]\w*:\s|\b\d|\b[A-Z]|=>|>>|#<|\$|\z))/

def highlight(line, t)
  line.scan(TOKEN_RE).map do |str, sym, key, num, const, punct, plain|
    color, text =
      if str then [t[:str], str]
      elsif sym then [t[:sym], sym]
      elsif key then [t[:key], key]
      elsif num then [t[:num], num]
      elsif const then [t[:const], const]
      elsif punct then [t[:muted], punct]
      else [nil, plain]
      end
    color ? %(<tspan fill="#{color}">#{esc(text)}</tspan>) : esc(text)
  end.join
end

def render(theme_name)
  t = THEMES[theme_name]
  css = +""
  els = +""
  clock = 0.6

  # --- console lines
  SCRIPT.each_with_index do |(kind, text), i|
    y = CON_Y + i * LINE_H
    base = %(x="#{CON_X}" y="#{y}")
    case kind
    when :shell, :muted, :out
      start = clock
      clock += kind == :out ? 0.08 : 0.35
      body = kind == :muted ? %(<tspan fill="#{t[:muted]}">#{esc(text)}</tspan>) : highlight(text, t)
      els << %(<text #{base} class="r" style="animation-delay:#{start.round(2)}s">#{body}</text>\n)
      clock += 0.25 if kind == :out && SCRIPT[i + 1]&.first != :out
    when :cmd
      prompt_w = 3 * CHAR_W
      dur = (text.length * TYPE_SPEED).round(2)
      start = clock + 0.2
      dist = (text.length * CHAR_W).round(1)
      css << "@keyframes t#{i}{to{transform:translateX(#{dist}px)}}\n"
      els << %(<text #{base} class="r" style="animation-delay:#{clock.round(2)}s"><tspan fill="#{t[:prompt]}">&gt;&gt;</tspan> #{highlight(text, t)}</text>\n)
      els << %(<g class="cover" style="animation:t#{i} #{dur}s steps(#{text.length}) #{start.round(2)}s both">) +
             %(<rect x="#{(CON_X + prompt_w).round(1)}" y="#{y - 14}" width="#{W}" height="#{LINE_H}" fill="#{t[:bg]}"/>) +
             %(<rect class="cur" x="#{(CON_X + prompt_w).round(1)}" y="#{y - 12}" width="8" height="15" fill="#{t[:str]}" ) +
             %(style="animation:on .01s #{clock.round(2)}s forwards, off .01s #{(start + dur + 0.1).round(2)}s forwards"/></g>\n)
      clock = start + dur + 0.35
    when :end
      els << %(<text #{base} class="r" style="animation-delay:#{clock.round(2)}s"><tspan fill="#{t[:prompt]}">&gt;&gt;</tspan></text>\n)
      els << %(<rect class="r" x="#{(CON_X + 3 * CHAR_W).round(1)}" y="#{y - 12}" width="8" height="15" fill="#{t[:str]}" ) +
             %(style="animation:r .01s #{clock.round(2)}s both, blink 1.1s steps(1) #{clock.round(2)}s infinite"/>\n)
    end
  end

  # --- chessboard: 64 days, oldest at a8, today at h1 (the knight)
  board = +""
  DAYS.each_with_index do |d, i|
    row, col = i.divmod(8)
    x = BOARD_X + col * SQ
    y = BOARD_Y + row * SQ
    lvl = LEVELS.index(d["contributionLevel"])
    n = d["contributionCount"]
    tip = "#{Date.parse(d["date"]).strftime("%b %-d")}: #{n} contribution#{"s" unless n == 1}"
    board << %(<rect x="#{x}" y="#{y}" width="#{SQ}" height="#{SQ}" fill="#{t[:sq][(row + col) % 2]}"><title>#{tip}</title></rect>\n)
    next unless lvl && i < DAYS.size - 1
    s = SQ * [0.3, 0.45, 0.6, 0.74][lvl]   # busier day = bigger piece
    o = (SQ - s) / 2
    board << %(<rect class="r" x="#{(x + o).round(1)}" y="#{(y + o).round(1)}" width="#{s.round(1)}" height="#{s.round(1)}" rx="3" fill="#{t[:lvl][lvl]}" style="animation-delay:#{(0.3 + i * 0.025).round(3)}s"><title>#{tip}</title></rect>\n)
  end
  kr, kc = (DAYS.size - 1).divmod(8)
  knight_fill = LEVELS.index(DAYS.last["contributionLevel"]) ? t[:lvl][3] : t[:piece]
  board << %(<text class="r" x="#{BOARD_X + kc * SQ + SQ / 2}" y="#{BOARD_Y + kr * SQ + 23}" text-anchor="middle" style="font-size:22px;fill:#{knight_fill};animation-delay:#{(0.3 + 64 * 0.025).round(2)}s">#{KNIGHT}</text>\n)
  files = ("a".."h").each_with_index.map { |f, i| %(<text x="#{BOARD_X + i * SQ + SQ / 2}" y="#{BOARD_Y + 8 * SQ + 16}" text-anchor="middle">#{f}</text>) }.join
  ranks = (1..8).to_a.reverse.each_with_index.map { |r, i| %(<text x="#{BOARD_X - 12}" y="#{BOARD_Y + i * SQ + 19}" text-anchor="middle">#{r}</text>) }.join
  from = Date.parse(DAYS.first["date"]).strftime("%b %-d")

  <<~SVG
    <svg xmlns="http://www.w3.org/2000/svg" width="#{W}" height="#{H}" viewBox="0 0 #{W} #{H}" role="img" aria-label="#{esc(PROFILE["name"])}, #{esc(PROFILE["role"])} from #{esc(PROFILE["city"])}. Stack: #{esc(PROFILE["stack"].join(", "))}.">
    <style>
      text{font-family:#{FONT};font-size:13px;fill:#{t[:text]};white-space:pre}
      .lbl text{font-size:10px;fill:#{t[:muted]}}
      .r{animation:r .25s ease-out both}
      .cur{opacity:0}
      @keyframes r{from{opacity:0}to{opacity:1}}
      @keyframes on{to{opacity:1}}
      @keyframes off{to{opacity:0}}
      @keyframes blink{0%{opacity:1}50%{opacity:0}}
      #{css.strip}
      @media (prefers-reduced-motion: reduce){.r,.r *{animation:none!important}.cover{display:none}}
    </style>
    <defs>
      <clipPath id="win"><rect width="#{W}" height="#{H}" rx="12"/></clipPath>
      <clipPath id="con"><rect x="#{CON_X}" y="40" width="#{W - CON_X - 16}" height="#{H - 48}"/></clipPath>
    </defs>
    <g clip-path="url(#win)">
      <rect width="#{W}" height="#{H}" fill="#{t[:bg]}"/>
      <rect width="#{W}" height="36" fill="#{t[:bar]}"/>
      <rect width="#{W}" height="2" fill="#0057b7"/><rect y="2" width="#{W}" height="2" fill="#ffd500"/>
      <line x1="0" y1="36" x2="#{W}" y2="36" stroke="#{t[:border]}"/>
      <circle cx="22" cy="20" r="6" fill="#ff5f57"/><circle cx="42" cy="20" r="6" fill="#febc2e"/><circle cx="62" cy="20" r="6" fill="#28c840"/>
      <text x="#{W / 2}" y="24" text-anchor="middle" style="font-size:12px;fill:#{t[:muted]}">volodymyr@lviv: ~/profile — rails console</text>
      #{board}
      <g class="lbl">#{files}#{ranks}
        <text x="#{BOARD_X + 4 * SQ}" y="#{BOARD_Y + 8 * SQ + 40}" text-anchor="middle">64 days of commits · #{from} → #{KNIGHT} today</text>
      </g>
      <line x1="#{CON_X - 24}" y1="56" x2="#{CON_X - 24}" y2="#{H - 20}" stroke="#{t[:border]}" stroke-dasharray="2 4"/>
      <g clip-path="url(#con)" xml:space="preserve">
    #{els}  </g>
    </g>
    <rect x=".5" y=".5" width="#{W - 1}" height="#{H - 1}" rx="12" fill="none" stroke="#{t[:border]}"/>
    </svg>
  SVG
end

Dir.mkdir(File.join(ROOT, "assets")) unless Dir.exist?(File.join(ROOT, "assets"))
THEMES.each_key do |name|
  File.write(File.join(ROOT, "assets", "console-#{name}.svg"), render(name))
end
puts "Rendered #{THEMES.size} cards: #{STATS}"
