import Foundation
import MemoryCore
import PrivacyPolicy

/// Deterministic fake secrets: random-looking, never real. `seed` keeps each
/// fixture stable between runs.
func fakeSecret(_ n: Int, _ alphabet: String = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789", seed: UInt64) -> String {
    let chars = Array(alphabet)
    var x = seed &* 6364136223846793005 &+ 1442695040888963407
    return String((0..<n).map { _ in
        x = x &* 6364136223846793005 &+ 1442695040888963407
        return chars[Int((x >> 33) % UInt64(chars.count))]
    })
}
let hexAlphabet = "0123456789abcdef"

private struct ScrubCase {
    let label: String
    let input: String
    /// Text that must not survive (the secret).
    let secrets: [String]
    /// A reason that must be among the redactions (or the drop reason).
    let reason: TypedSecretScrubber.Reason
    /// nil = any kept text; otherwise the exact kept text.
    var expected: String? = nil
    var drop = false
}

/// Safe typing C: the store-side scrubber (pure, then through ingest) and
/// the terminal prompt latch's shared command rule.
func runTypedScrubberChecks(home: URL) throws {
    typealias R = TypedSecretScrubber.Reason
    let m = TypedSecretScrubber.marker

    // MARK: Positives: one or more real-looking fixtures per rule.
    let anthropic = "sk-ant-api03-" + fakeSecret(40, seed: 1) + "-" + fakeSecret(12, seed: 2)
    let openai = "sk-proj-" + fakeSecret(40, seed: 3)
    let openrouter = "sk-or-v1-" + fakeSecret(64, hexAlphabet, seed: 4)
    let github = "ghp_" + fakeSecret(36, seed: 5)
    let githubPat = "github_pat_11" + fakeSecret(20, seed: 6) + "_" + fakeSecret(59, seed: 7)
    let gitlab = "glpat-" + fakeSecret(20, seed: 8)
    let slack = "xoxb-1234567890-1234567890123-" + fakeSecret(24, seed: 9)
    let slackHook = "https://hooks.slack.com/services/T0FIXTURE/B0FIXTURE/" + fakeSecret(24, seed: 10)
    let stripe = "sk_live_" + fakeSecret(24, seed: 11)
    let stripeHook = "whsec_" + fakeSecret(32, seed: 12)
    let aws = "AKIAIOSFODNN7EXAMPLE"
    let awsExample = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
    let awsSecret = fakeSecret(40, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", seed: 37)
    let google = "AIza" + fakeSecret(35, seed: 13)
    let googleOAuth = "ya29." + fakeSecret(40, seed: 14)
    let googleClient = "GOCSPX-" + fakeSecret(28, seed: 15)
    let npm = "npm_" + fakeSecret(36, seed: 16)
    let pypi = "pypi-AgEIcHlwaS5vcmc" + fakeSecret(60, seed: 17)
    let hf = "hf_" + fakeSecret(34, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz", seed: 18)
    let sendgrid = "SG." + fakeSecret(22, seed: 19) + "." + fakeSecret(43, seed: 20)
    let twilio = "SK" + fakeSecret(32, hexAlphabet, seed: 21)
    let digitalocean = "dop_v1_" + fakeSecret(64, hexAlphabet, seed: 22)
    let shopify = "shpat_" + fakeSecret(32, hexAlphabet, seed: 23)
    let telegram = "123456789:A" + fakeSecret(34, seed: 24)
    let jwt = "eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJmaXh0dXJlIn0." + fakeSecret(30, seed: 25)
    let groq = "gsk_" + fakeSecret(48, seed: 26)
    let replicate = "r8_" + fakeSecret(37, seed: 27)
    let linear = "lin_api_" + fakeSecret(40, seed: 28)
    let databricks = "dapi" + fakeSecret(32, hexAlphabet, seed: 29)
    let mailgun = "key-" + fakeSecret(32, hexAlphabet, seed: 30)
    let notion = "ntn_" + fakeSecret(46, seed: 31)
    let supabase = "sbp_" + fakeSecret(40, hexAlphabet, seed: 32)
    let random24 = fakeSecret(24, seed: 33)
    let random40 = fakeSecret(40, "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/", seed: 34)
    let sha = fakeSecret(40, hexAlphabet, seed: 35)
    let dbPass = "Pa55" + fakeSecret(8, seed: 36)
    // Review findings: secrets the first version kept.
    let symbolPass = "Us*d^MlH%UvTC&*#QCyEZDz%"
    let onePassword = "A3-BJ3J4W-J99IBA-G7I1M-NBQNS-6PUQ8-0IDW3"
    let appleRecovery = "706I-8J76-B2LA-JLJ4-H9DU-7794-G9DP"
    let seed = "legal winner thank year wave sausage worth useful legal winner thank yellow"
    let cutKey = "sk-ant-api03-PtYgjmU"
    let chunkedKey = ["sk-ant-api03-mrcX" + fakeSecret(10, seed: 40), fakeSecret(12, seed: 41) + "7", "Q" + fakeSecret(12, seed: 42) + "2"]

    let positives: [ScrubCase] = [
        .init(label: "Anthropic key", input: "use \(anthropic) for the demo", secrets: [anthropic], reason: .providerToken, expected: "use \(m) for the demo"),
        .init(label: "OpenAI project key", input: "OpenAI key \(openai) rotated", secrets: [openai], reason: .providerToken),
        .init(label: "OpenRouter key", input: "router \(openrouter)", secrets: [openrouter], reason: .providerToken),
        .init(label: "GitHub classic token", input: "token \(github) expires soon", secrets: [github], reason: .providerToken),
        .init(label: "GitHub fine-grained token", input: "pat \(githubPat) done", secrets: [githubPat], reason: .providerToken),
        .init(label: "GitLab token", input: "gitlab \(gitlab) ok", secrets: [gitlab], reason: .providerToken),
        .init(label: "Slack bot token", input: "slack bot \(slack) ok", secrets: [slack], reason: .providerToken),
        .init(label: "Slack webhook", input: "post to \(slackHook) please", secrets: [slackHook, "B0FIXTURE"], reason: .providerToken),
        .init(label: "Stripe secret key", input: "stripe \(stripe) live", secrets: [stripe], reason: .providerToken),
        .init(label: "Stripe webhook secret", input: "hook \(stripeHook)", secrets: [stripeHook], reason: .providerToken),
        .init(label: "AWS access key id", input: "aws id \(aws) today", secrets: [aws], reason: .providerToken),
        .init(label: "AWS secret key (entropy)", input: "the aws secret is \(awsSecret) ok", secrets: [awsSecret], reason: .highEntropy),
        .init(label: "AWS secret key assignment", input: "aws_secret_access_key = \(awsExample)", secrets: [awsExample], reason: .assignment),
        .init(label: "Google API key", input: "maps \(google) key", secrets: [google], reason: .providerToken),
        .init(label: "Google OAuth token", input: "oauth \(googleOAuth)", secrets: [googleOAuth], reason: .providerToken),
        .init(label: "Google client secret", input: "client \(googleClient)", secrets: [googleClient], reason: .providerToken),
        .init(label: "npm token", input: "npm \(npm)", secrets: [npm], reason: .providerToken),
        .init(label: "PyPI token", input: "pypi \(pypi)", secrets: [pypi], reason: .providerToken),
        .init(label: "Hugging Face token", input: "hf \(hf)", secrets: [hf], reason: .providerToken),
        .init(label: "SendGrid key", input: "mail \(sendgrid)", secrets: [sendgrid], reason: .providerToken),
        .init(label: "Twilio key", input: "twilio \(twilio)", secrets: [twilio], reason: .providerToken),
        .init(label: "DigitalOcean token", input: "do \(digitalocean)", secrets: [digitalocean], reason: .providerToken),
        .init(label: "Shopify token", input: "shop \(shopify)", secrets: [shopify], reason: .providerToken),
        .init(label: "Telegram bot token", input: "bot \(telegram)", secrets: [telegram], reason: .providerToken),
        .init(label: "JWT", input: "jwt \(jwt) expired", secrets: [jwt], reason: .providerToken),
        .init(label: "Groq key", input: "groq \(groq)", secrets: [groq], reason: .providerToken),
        .init(label: "Replicate token", input: "replicate \(replicate)", secrets: [replicate], reason: .providerToken),
        .init(label: "Linear key", input: "linear \(linear)", secrets: [linear], reason: .providerToken),
        .init(label: "Databricks token", input: "dbx \(databricks)", secrets: [databricks], reason: .providerToken),
        .init(label: "Mailgun key", input: "mailgun \(mailgun)", secrets: [mailgun], reason: .providerToken),
        .init(label: "Notion token", input: "notion \(notion)", secrets: [notion], reason: .providerToken),
        .init(label: "Supabase token", input: "supabase \(supabase)", secrets: [supabase], reason: .providerToken),
        .init(label: "random base62 token", input: "the value was \(random24) ok", secrets: [random24], reason: .highEntropy, expected: "the value was \(m) ok"),
        .init(label: "random base64 token", input: "blob \(random40) end", secrets: [random40], reason: .highEntropy),
        .init(label: "full git SHA (accepted)", input: "reverted \(sha) today", secrets: [sha], reason: .highEntropy),
        .init(label: "connection string", input: "postgres://admin:\(dbPass)@db.internal:5432/app is prod", secrets: [dbPass], reason: .connectionString),
        .init(label: "git URL with token", input: "git clone https://sam:\(github)@github.com/x/y.git", secrets: [github], reason: .providerToken),
        .init(label: ".env assignment", input: "export OPENAI_API_KEY=abc123def456ghi", secrets: ["abc123def456ghi"], reason: .assignment, expected: "export OPENAI_API_KEY=\(m)"),
        .init(label: "quoted password assignment", input: "DB_PASSWORD='correct horse battery staple'", secrets: ["correct horse", "staple"], reason: .assignment),
        .init(label: "password colon", input: "wifi password: hunter2 for guests", secrets: ["hunter2"], reason: .assignment),
        .init(label: "JSON client secret", input: #"{"client_secret": "shhh-not-real-123", "id": 4}"#, secrets: ["shhh-not-real-123"], reason: .assignment),
        .init(label: "camelCase key assignment", input: "const apiKey = \"q8Zt2mR5vX\";", secrets: ["q8Zt2mR5vX"], reason: .assignment),
        .init(label: "password = plain word", input: "password = sunshine", secrets: ["sunshine"], reason: .assignment),
        .init(label: "URL query token", input: "callback?access_token=zz9yy8xx7&state=1", secrets: ["zz9yy8xx7"], reason: .assignment),
        .init(label: "Bearer header", input: "curl -H 'Authorization: Bearer abc.def.ghi-123' https://api.example.com", secrets: ["abc.def.ghi-123"], reason: .authHeader),
        .init(label: "Basic header", input: "Authorization: Basic dXNlcjpwYXNzd29yZA==", secrets: ["dXNlcjpwYXNzd29yZA=="], reason: .authHeader),
        .init(label: "bare Bearer token", input: "send Bearer tok_4f9a8b7c6d with it", secrets: ["tok_4f9a8b7c6d"], reason: .authHeader),
        .init(label: "X-Api-Key header", input: "X-Api-Key: 1234abcd5678efgh", secrets: ["1234abcd5678efgh"], reason: .authHeader),
        .init(label: "Cookie header", input: "Cookie: session=abc123; theme=dark", secrets: ["abc123"], reason: .authHeader),
        .init(label: "CLI --password", input: "deploy --password hunter2 --verbose", secrets: ["hunter2"], reason: .cliSecretFlag, expected: "deploy --password \(m) --verbose"),
        .init(label: "CLI --api-key=", input: "tool --api-key=q1w2e3r4 run", secrets: ["q1w2e3r4"], reason: .cliSecretFlag),
        .init(label: "CLI --token", input: "gh-cli --token plainword now", secrets: ["plainword"], reason: .cliSecretFlag),
        .init(label: "curl -u user:pass", input: "curl -u sam:hunter2 https://api.example.com", secrets: ["hunter2"], reason: .cliSecretFlag),
        .init(label: "openssl -pass", input: "openssl enc -aes256 -pass pass:hunter2 -in a", secrets: ["hunter2"], reason: .cliSecretFlag),
        .init(label: "Visa test card (Luhn)", input: "card 4111 1111 1111 1111 exp 12/27 cvv 123 thanks", secrets: ["4111", "12/27", "123 thanks"], reason: .paymentCard, expected: "card \(m) exp \(m) cvv \(m) thanks"),
        .init(label: "card with dashes", input: "use 5555-5555-5555-4444 please", secrets: ["5555-5555"], reason: .paymentCard),
        .init(label: "long number that is not a card", input: "ticket 9999999999999 closed", secrets: ["9999999999999"], reason: .longNumber),
        .init(label: "20+ digit run", input: "ref 123456789012345678901234 ok", secrets: ["123456789012345678901234"], reason: .longNumber),
        .init(label: "SSN dashed", input: "my ssn is 123-45-6789 ok", secrets: ["123-45-6789"], reason: .ssn),
        .init(label: "SSN spaced", input: "number 123 45 6789 on file", secrets: ["123 45 6789"], reason: .ssn),
        .init(label: "bare 9 digits near SSN", input: "SSN 123456789 for the form", secrets: ["123456789"], reason: .ssn),
        .init(label: "bare 9 digits near tax id", input: "tax id is 987654321 now", secrets: ["987654321"], reason: .ssn),
        .init(label: "verification code", input: "your verification code is 482913 thanks", secrets: ["482913"], reason: .oneTimeCode),
        .init(label: "Google G- code", input: "G-123456 is your Google verification code", secrets: ["123456"], reason: .oneTimeCode),
        .init(label: "2fa ddd ddd", input: "2fa 123 456 entered", secrets: ["123 456"], reason: .oneTimeCode),
        .init(label: "login code", input: "login code 4829 expires", secrets: ["4829"], reason: .oneTimeCode),
        .init(label: "pin year right after label", input: "pin 1987 for the bike lock", secrets: ["1987"], reason: .passwordLabel),
        .init(label: "code year right after label", input: "sign-in code 2024 sent", secrets: ["2024"], reason: .oneTimeCode),
        .init(label: "lone code unit", input: "482913", secrets: ["482913"], reason: .oneTimeCode, drop: true),
        .init(label: "lone dashed code unit", input: " 482-913 ", secrets: ["482"], reason: .oneTimeCode, drop: true),
        .init(label: "password prose", input: "the wifi password is hunter2 btw", secrets: ["hunter2"], reason: .passwordLabel, expected: "the wifi password is \(m)"),
        .init(label: "passphrase after a label", input: "the password is: correct horse battery staple", secrets: ["correct", "horse", "battery", "staple"], reason: .passwordLabel, expected: "the password is: \(m)"),
        .init(label: "passphrase ends at the sentence", input: "My password is purple monkey dishwasher. See you at 5", secrets: ["purple", "monkey", "dishwasher"], reason: .passwordLabel, expected: "My password is \(m). See you at 5"),
        .init(label: "generated password with symbols", input: "new login Us*d^MlH%UvTC&*#QCyEZDz% saved", secrets: [symbolPass, "UvTC"], reason: .highEntropy, expected: "new login \(m) saved"),
        .init(label: "1Password Secret Key", input: "secret key \(onePassword) keep safe", secrets: [onePassword, "J99IBA"], reason: .recoveryCode),
        .init(label: "Apple recovery key", input: "apple recovery key \(appleRecovery)", secrets: [appleRecovery, "B2LA"], reason: .recoveryCode),
        .init(label: "GitHub recovery codes", input: "codes fb008-f86be 4c1ce-9e2a1 done", secrets: ["fb008-f86be", "4c1ce-9e2a1"], reason: .recoveryCode),
        .init(label: "Google app password after its label", input: "gmail app password: bgcg ofdk tbda serd", secrets: ["bgcg", "serd"], reason: .recoveryCode),
        .init(label: "lone Google app password", input: "bgcg ofdk tbda serd", secrets: ["bgcg"], reason: .recoveryCode, drop: true),
        .init(label: "wallet recovery phrase", input: "backup\n\(seed)\nend", secrets: ["sausage", "winner"], reason: .recoveryPhrase, expected: "backup\n\(m)\nend"),
        .init(label: "card with dots", input: "card 4111.1111.1111.1111 on file", secrets: ["4111.1111", "1111.1111"], reason: .paymentCard),
        .init(label: "card split over two lines", input: "number 4111 1111\n1111 1111 ok", secrets: ["4111 1111", "1111 1111"], reason: .paymentCard),
        .init(label: "SSN with dots", input: "ssn 123.45.6789 on the form", secrets: ["123.45.6789", "6789"], reason: .ssn),
        .init(label: "expiry and CVV after a card, no labels", input: "4111111111111111 08/27 123 thanks", secrets: ["4111", "/27", "123"], reason: .paymentCard, expected: "\(m) thanks"),
        .init(label: "key typed in chunks", input: "key " + chunkedKey.joined(separator: " ") + " done", secrets: chunkedKey, reason: .providerToken, expected: "key \(m) done"),
        .init(label: "key cut by a unit split", input: "paste \(cutKey)", secrets: [cutKey, "PtYgjmU"], reason: .providerToken, expected: "paste \(m)"),
        .init(label: "AWS secret without =", input: "aws_secret_access_key \(awsSecret)", secrets: [awsSecret], reason: .assignment),
        .init(label: "pin prose", input: "my pin is 4921 ok", secrets: ["4921"], reason: .passwordLabel),
        .init(label: "door code prose", input: "door code 7788 for the office", secrets: ["7788"], reason: .passwordLabel),
        .init(label: "password label then value line", input: "Password:\nhunter2", secrets: ["hunter2"], reason: .passwordLabel, expected: "Password:\n\(m)"),
        .init(label: "OpenSSH private key", input: "key:\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAA\n-----END OPENSSH PRIVATE KEY-----", secrets: ["b3Blbn"], reason: .privateKey, drop: true),
        .init(label: "PGP private key", input: "-----BEGIN PGP PRIVATE KEY BLOCK-----\nlQOYBF", secrets: ["lQOYBF"], reason: .privateKey, drop: true),
        .init(label: "RSA private key with odd spacing", input: "-----BEGIN\u{00A0}RSA PRIVATE KEY-----\nMIIE", secrets: ["MIIE"], reason: .privateKey, drop: true),
        .init(label: "token-only unit", input: "  \(github)  ", secrets: [github], reason: .providerToken, drop: true),
        .init(label: "sudo keeps the command word", input: "sudo apt install nginx", secrets: ["nginx"], reason: .privilegedCommand, expected: "sudo \(m)"),
        .init(label: "sudo then password line", input: "sudo -k\nhunter2\nls -la", secrets: ["hunter2"], reason: .afterPrivilegedCommand, expected: "sudo \(m)\n\(m)\nls -la"),
        .init(label: "bare sudo then password", input: "sudo\nhunter2", secrets: ["hunter2"], reason: .afterPrivilegedCommand, expected: "sudo\n\(m)"),
        .init(label: "blank line before the password", input: "sudo whoami\n\nhunter2", secrets: ["hunter2", "whoami"], reason: .afterPrivilegedCommand, expected: "sudo \(m)\n\n\(m)"),
        .init(label: "ssh target withheld", input: "ssh admin@10.0.0.5", secrets: ["admin@10.0.0.5"], reason: .privilegedCommand, expected: "ssh \(m)"),
        .init(label: "chained sudo", input: "cd /tmp && sudo make install", secrets: ["make install"], reason: .privilegedCommand, expected: "cd /tmp && sudo \(m)"),
        .init(label: "piped into sudo -S", input: "ok then\necho hunter2 | sudo -S apt update", secrets: ["hunter2"], reason: .privilegedCommand, expected: "ok then\n\(m)"),
        .init(label: "env password before psql", input: "PGPASSWORD=hunter2 psql -h db", secrets: ["hunter2", "-h db"], reason: .privilegedCommand, expected: "\(m) psql \(m)"),
        .init(label: "docker login", input: "docker login -u sam registry.example.com", secrets: ["sam"], reason: .privilegedCommand, expected: "docker login \(m)"),
        .init(label: "security unlock-keychain", input: "security unlock-keychain -p hunter2 login.keychain", secrets: ["hunter2"], reason: .privilegedCommand, expected: "security unlock-keychain \(m)"),
        .init(label: "sudo by full path", input: "/usr/bin/sudo whoami", secrets: ["whoami"], reason: .privilegedCommand, expected: "/usr/bin/sudo \(m)"),
        .init(label: "gh auth login", input: "gh auth login --with-token", secrets: ["--with-token"], reason: .privilegedCommand, expected: "gh auth login \(m)"),
        .init(label: "su root then password", input: "su root\nhunter2", secrets: ["hunter2", "root"], reason: .afterPrivilegedCommand, expected: "su \(m)\n\(m)"),
        .init(label: "mysql -p value", input: "mysql -u root -pS3cret db", secrets: ["S3cret"], reason: .privilegedCommand, expected: "mysql \(m)"),
        .init(label: "shell prompt marker", input: "$ sudo reboot", secrets: ["reboot"], reason: .privilegedCommand, expected: "$ sudo \(m)"),
        .init(label: "NBSP and zero-width inside a token", input: "key\u{00A0}\u{200B}\(github)", secrets: [github], reason: .providerToken),
        .init(label: "full-width digits card", input: "card ４１１１ １１１１ １１１１ １１１１ ok", secrets: ["4111"], reason: .paymentCard),
        // Review round 1 (TypedSecretScrubber robustness): card separators the rules listed one at a time.
        .init(label: "card joined by commas", input: "card 4111,1111,1111,1111 exp", secrets: ["4111", "1111"], reason: .paymentCard, expected: "card \(m) exp"),
        .init(label: "card joined by comma and space", input: "card 5555, 5555, 5555, 4444 ok", secrets: ["5555", "4444"], reason: .paymentCard, expected: "card \(m) ok"),
        .init(label: "card joined by plus", input: "card 5555+5555+5555+4444 ok", secrets: ["5555", "4444"], reason: .paymentCard, expected: "card \(m) ok"),
        .init(label: "card joined by colons", input: "card 4111:1111:1111:1111 ok", secrets: ["4111", "1111"], reason: .paymentCard, expected: "card \(m) ok"),
        .init(label: "card joined by pipes", input: "card 4111|1111|1111|1111 ok", secrets: ["4111", "1111"], reason: .paymentCard, expected: "card \(m) ok"),
        .init(label: "card joined by double dashes", input: "card 4111 -- 1111 -- 1111 -- 1111 ok", secrets: ["4111", "1111"], reason: .paymentCard, expected: "card \(m) ok"),
        .init(label: "amex joined by commas", input: "amex 3782,822463,10005 ok", secrets: ["822463", "10005"], reason: .paymentCard, expected: "amex \(m) ok"),
        // Passwords labelled without "is" or ":", before or after the label.
        .init(label: "pw then password", input: "pw Fluffy123", secrets: ["Fluffy123"], reason: .passwordLabel, expected: "pw \(m)"),
        .init(label: "pwd then password", input: "pwd Fluffy123", secrets: ["Fluffy123"], reason: .passwordLabel, expected: "pwd \(m)"),
        .init(label: "password then password", input: "password Fluffy123", secrets: ["Fluffy123"], reason: .passwordLabel, expected: "password \(m)"),
        .init(label: "password before is my password", input: "Fluffy123 is my password", secrets: ["Fluffy123"], reason: .passwordLabel, expected: "\(m) is my password"),
        .init(label: "Password dash", input: "Password - Fluffy123", secrets: ["Fluffy123"], reason: .passwordLabel, expected: "Password - \(m)"),
        .init(label: "wifi pw", input: "wifi pw Blue42Sky99", secrets: ["Blue42Sky99"], reason: .passwordLabel, expected: "wifi pw \(m)"),
        .init(label: "gmail pw", input: "gmail pw Fluffy123", secrets: ["Fluffy123"], reason: .passwordLabel, expected: "gmail pw \(m)"),
        .init(label: "home wifi colon", input: "home wifi: Blue42Sky99", secrets: ["Blue42Sky99"], reason: .passwordLabel, expected: "home wifi: \(m)"),
        .init(label: "username then password", input: "username sam password Fluffy123", secrets: ["Fluffy123"], reason: .passwordLabel, expected: "username sam password \(m)"),
        .init(label: "login name password", input: "login sam hunter22", secrets: ["hunter22"], reason: .privilegedCommand),
        .init(label: "password label ends the line", input: "password\nFluffy123", secrets: ["Fluffy123"], reason: .passwordLabel, expected: "password\n\(m)"),
        // Label chains: the first label no longer hides the second (the assignment rule looks again inside a value it turned down).
        .init(label: "label chain bank login", input: "Bank login: password: Summer2024!", secrets: ["Summer2024"], reason: .assignment, expected: "Bank login: password: \(m)"),
        .init(label: "label chain todo", input: "todo: password: Fluffy123", secrets: ["Fluffy123"], reason: .assignment, expected: "todo: password: \(m)"),
        .init(label: "label chain over a line", input: "Netflix:\npassword: Fluffy123", secrets: ["Fluffy123"], reason: .assignment, expected: "Netflix:\npassword: \(m)"),
        .init(label: "short password with four kinds", input: "note Tr0ub4dor&3 ok", secrets: ["Tr0ub4dor"], reason: .highEntropy, expected: "note \(m) ok"),
    ]

    // MARK: Negatives and near misses: kept exactly.
    let negatives: [String] = [
        "pricing page ships Friday",
        "sk-etch the idea before Friday",
        "FY2026 plan is due",
        "exit code 1 again",
        "dress code: casual",
        "fixed in commit a1b2c3d yesterday",
        "see 550e8400-e29b-41d4-a716-446655440000 in the log",
        "Key: ship Friday",
        "The password is on the fridge",
        "secret: always salt the water",
        "Password: on the fridge",
        "su casa es bonita",
        "login page redesign ships next week",
        "Security review on Friday",
        "security review on friday",
        "notes | login redesign",
        "turkey = 12 lbs",
        "author: Sam Lee",
        "Authorization: pending legal review",
        "Cookie: chocolate chip",
        "call me at 415-555-0123",
        "meeting at 10:30 on 2026-09-24",
        "zip code 94107",
        "error code 4040 again",
        "the pin is on the map",
        "bearer of bad news",
        "bearer instrument",
        "getUserAccountSettingsHandler2 returns quickly",
        "IMG_20260924_123456.jpg is attached",
        "com.googlecode.iterm2 crashed",
        "https://docs.example.com/guide?page=2",
        "~/src/security/notes.md",
        "we sold 1200 units in Q3 2026",
        "sign-in flow launches in 2026",
        "let tokenCount = tokens.count",
        "password = request.form.password",
        "token = newToken",
        "if apiKey == nil { return }",
        "func handleLogin(user: String, password: String) -> Bool {",
        "const token = await getToken();",
        "self.apiKey = apiKey",
        "The auth token expires in 3600 seconds",
        "session_id: 7f3a9c",
        "user_id=4821&page=3",
        "export PATH=/opt/homebrew/bin:$PATH",
        "docker run -p 8080:80 nginx",
        "Call 1-800-555-0199 for support",
        "passwordless login is the goal",
        "Typed in Slack #design: pricing page ships Friday",
        "ssh-keygen docs are confusing",
        "time to ship it",
        "Monkey: 3 bananas",
        "the keyboard shortcut is Control-Option-Command-T",
        "Q3",
        "abc",
        // Near misses for the review's new rules.
        "Q3-2026-OKRs are due",
        "state-of-the-art design work",
        "#design-review at 3",
        "best taco near home",
        "user_name-2024 signed up",
        "call 415.555.0123 today",
        "version 1.2.3.4 shipped",
        "please review the draft slides before tomorrow morning with design team leads",
        "The password is on the fridge.",
        "a+b=c in the notes",
        "P@ss is short",
        "the ghp_ prefix names GitHub tokens",
        // Review round 1: near misses for the widened card separators and the password labels.
        "sales 2023, 2024, 2025, 2026 grew",
        "slots 20:30, 21:45, 22:15, 23:20 work",
        "call 555-123-4567, 555-987-6543",
        "totals 4,500, 3,200, 6,100, 2,900",
        "scores 45, 67, 89, 23, 56, 78, 90",
        "pass the salt please",
        "password reset link sent",
        "the wifi is down again",
        "boarding pass is in my bag",
        "my password manager is great",
        "use a strong password please",
        "sign in with Google tomorrow",
        "pw reset at noon",
        "wifi at the office is slow",
        "the pass was closed for snow",
        "log in and check the dashboard",
        "the wifi password is on the fridge",
        "iPhone15 is my favourite",
        "Mary-Jane2024 signed up",
        "https://example.com/login?next=/home2024",
        "version v2.3.1 is my password manager",
    ]

    // Table rows report every failure before stopping.
    var failures: [String] = []
    func soft(_ ok: Bool, _ name: String) { if ok { print("PASS: " + name) } else { failures.append(name) } }
    for c in positives {
        let result = TypedSecretScrubber.scrub(c.input)
        let kept = result.kept ?? ""
        soft(!c.secrets.contains(where: { kept.contains($0) }), "scrub: \(c.label): the secret is gone")
        if c.drop {
            soft(result == .drop(c.reason), "scrub: \(c.label): the unit is dropped (\(c.reason.rawValue))")
        } else {
            soft(result.kept != nil && result.reasons.contains(c.reason), "scrub: \(c.label): kept with reason \(c.reason.rawValue)")
            if let expected = c.expected { soft(kept == expected, "scrub: \(c.label): exact kept text") }
        }
        // Reasons and descriptions carry codes only, never matched text.
        let described = String(describing: result) + String(reflecting: result) + result.reasons.map(\.rawValue).joined()
        var dumped = ""; dump(result, to: &dumped)
        soft(!c.secrets.contains(where: { described.contains($0) || dumped.contains($0) }), "scrub: \(c.label): no description or dump contains the match")
    }
    for text in negatives {
        let result = TypedSecretScrubber.scrub(text)
        soft(result == .keep(text, redactions: []), "scrub near miss kept exactly: \(text)")
    }
    try check(failures.isEmpty, "scrub table: " + (failures.isEmpty ? "all rows" : failures.joined(separator: " | ")))
    try check(TypedSecretScrubber.scrub("pricing\u{00A0}\u{00A0}page  ships\u{200B} Friday") == .keep("pricing page ships Friday", redactions: []), "scrub: whitespace is normalised (NBSP, runs of spaces, zero-width)")
    try check(TypedSecretScrubber.Reason.allCases.allSatisfy { $0.rawValue.range(of: "^[a-zA-Z]+$", options: .regularExpression) != nil }, "scrub: every reason is a plain code word")
    try check(TypedSecretScrubber.version == "typed-scrub/v1", "scrub: version string is typed-scrub/v1")
    try check(TypedSecretScrubber.looksLikeCard("4111111111111111") && !TypedSecretScrubber.looksLikeCard("4111111111111112") && !TypedSecretScrubber.looksLikeCard("9999999999999"), "scrub: Luhn and issuer prefix only name the card reason")
    // A cut at the size limit never keeps the first part of a token.
    let long = String(repeating: "word ", count: 818) + "ab" + github
    let cut = TypedSecretScrubber.scrub(long).kept ?? ""
    try check(!cut.contains("ghp_") && !cut.contains(String(github.prefix(10))) && cut.count <= 4096, "scrub: input past 4096 characters is cut at a word boundary, dropping the cut token")
    // Bounded work on hostile 4 KB input (debug build): no runaway backtracking.
    for hostile in [String(repeating: "1 ", count: 2048), String(repeating: "a=", count: 2048), String(repeating: "password is ", count: 340),
                    String(repeating: "-----BEGIN ", count: 372), String(repeating: "x", count: 4096), String(repeating: "sudo a\n", count: 585),
                    String(repeating: "code 1234 ", count: 409), String(repeating: "ab:cd@", count: 682)] {
        let start = Date(); _ = TypedSecretScrubber.scrub(hostile)
        try check(Date().timeIntervalSince(start) < 2.0, "scrub: hostile input of \(hostile.count) characters finishes quickly")
    }
    // Tables per rule: every Reason has at least one positive fixture.
    try check(Set(positives.map(\.reason)) == Set(R.allCases), "scrub: every reason code has a fixture")

    // MARK: The command rule is the same in the store and in the latch.
    try check(TypedSecretScrubber.privilegedCommands == TerminalPromptLatch.privilegedCommands && TypedSecretScrubber.privilegedPhrases == TerminalPromptLatch.privilegedPhrases, "scrub/latch: the same privileged command lists")
    let commandLines = ["sudo apt update", "ssh me@host", "  env FOO=1 sudo -E make", "time scp a b:c", "PGPASSWORD=x psql", "cd /tmp && sudo make", "echo x | sudo -S ls", "docker login", "gh auth login", "security unlock-keychain", "su", "su - admin", "login", "/usr/bin/sudo -i",
                        "ls -la", "su casa es bonita", "login page redesign ships", "security review", "Security find-generic-password", "notes | login redesign", "~/bin/sudo x", "sudoku tonight", "pricing page ships Friday", ""]
    for line in commandLines {
        try check(TypedSecretScrubber.isPrivilegedCommandLine(line) == TerminalPromptLatch.isPrivilegedCommandLine(line), "scrub/latch agree on a command line (\(line.isEmpty ? "empty" : String(line.prefix(12))))")
    }
    try check(commandLines.prefix(14).allSatisfy(TypedSecretScrubber.isPrivilegedCommandLine) && !commandLines.dropFirst(14).contains(where: TypedSecretScrubber.isPrivilegedCommandLine), "scrub: the command table splits as expected")

    // MARK: Through ingest (public store API, in-memory keys only).
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let store = try MemoryStore(home: home, writable: true, automaticallySyncSearch: false)
    var consent = try store.policy(); consent.captureText = true; consent.typedConsentVersion = 1; try store.updatePolicy(consent, now: now)
    // TextEdit: while the release gate is closed only Notes and TextEdit
    // record typing (a Terminal case below). The rules are the same in any app.
    func typed(_ id: String, _ text: String, bundle: String = "com.apple.TextEdit") -> Evidence {
        var e = Evidence(id: id, at: iso(now), kind: "keyboard.text_input", app: bundle == "com.apple.Terminal" ? "Terminal" : "TextEdit", bundle: bundle, title: "zsh", text: text, synthetic: true)
        e.captureProvenance = NativeCaptureProvenance(policyRevision: "r", classifierVersion: "sensitive-typing/v2", windowID: "w", focusID: "f", checkedAt: e.at, generation: 1,
                                                      unit: TypedUnitProvenance(runID: "run", part: 1, sealReason: "return", startedAt: e.at, keys: 40, edits: 2, withheld: 0))
        return e
    }
    // Before a vault: a secret-only unit is dropped quietly; any other unit still throws.
    try check(try !store.ingest(typed("s-lone", "482913"), now: now) && store.read("s-lone", now: now) == nil, "ingest: a lone code unit is dropped even before the vault (nothing written, no throw)")
    var locked = false
    do { _ = try store.ingest(typed("s-locked", "deploy --password hunter2 now"), now: now) } catch { locked = true }
    try check(locked && (try store.read("s-locked", now: now)) == nil, "ingest: scrubbing never unlocks typing: a kept unit still needs the vault")
    try attachTestVault(store)
    try check(try store.ingest(typed("s1", "deploy with \(openai) today"), now: now), "ingest: a unit with a key is kept")
    let s1 = try store.hydrateTypedText("s1", disclosure: .owner, now: now) ?? ""
    try check(s1 == "deploy with \(m) today", "ingest: the owner opens the scrubbed words, the key withheld")
    let item = try store.read("s1", now: now)
    try check(item?.evidence.captureProvenance?.classifierVersion == "sensitive-typing/v2+typed-scrub/v1", "ingest: the provenance names typed-scrub/v1")
    try check(item?.evidence.captureProvenance?.unit?.withheld == 1 && item?.evidence.captureProvenance?.unit?.keys == nil && item?.evidence.captureProvenance?.unit?.edits == nil, "ingest: a withheld span is counted and key/edit counts are cleared")
    try check(item?.evidence.typed?.words == 4, "ingest: the word count is of the scrubbed text")
    try check(try store.ingest(typed("s2", "sudo apt update\nhunter2\nls"), now: now), "ingest: a unit with sudo is kept")
    try check(try store.hydrateTypedText("s2", disclosure: .owner, now: now) == "sudo \(m) \(m) ls", "ingest: sudo keeps the command word; the next line is withheld")
    try check(try !store.ingest(typed("s3", "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjE"), now: now) && store.read("s3", now: now) == nil, "ingest: a private key drops the unit")
    try check(try !store.ingest(typed("s4", "  \(github) "), now: now) && store.read("s4", now: now) == nil, "ingest: a token-only unit is dropped")
    try check(try store.ingest(typed("s5", "pricing page ships Friday"), now: now) && store.hydrateTypedText("s5", disclosure: .owner, now: now) == "pricing page ships Friday", "ingest: ordinary words are unchanged")
    try check(try store.read("s5", now: now)?.evidence.captureProvenance?.unit?.keys == 40, "ingest: nothing withheld keeps the key count")
    try check(try store.typedCounts() == (3, 0), "ingest: only kept units were sealed")
    // Terminal: refused by the closed gate in a narrow build; kept (and scrubbed) in the full-typing build every release stage makes.
    if OwnerTyping.enabled {
        try check(try store.ingest(typed("s-terminal", "git status", bundle: "com.apple.Terminal"), now: now) && store.read("s-terminal", now: now) != nil && store.typedCounts() == (4, 0), "ingest: full-typing build: Terminal typing is kept (Code is on by default)")
    } else {
        try check(try !store.ingest(typed("s-terminal", "git status", bundle: "com.apple.Terminal"), now: now) && store.read("s-terminal", now: now) == nil && store.typedCounts() == (3, 0), "ingest: Terminal typing is refused while the release gate is closed")
    }
    let sealedKept = OwnerTyping.enabled ? 4 : 3
    // The nets stack: after "KEY=[withheld]" the existing store rule
    // (Privacy.secret, unchanged) still withholds the whole text.
    try check(try store.ingest(typed("s6", "export OPENAI_API_KEY=abc123def456ghi"), now: now), "ingest: an assignment unit keeps its record")
    try check(try store.read("s6", now: now)?.evidence.text == "" && store.read("s6", now: now)?.evidence.typed == nil && store.typedCounts() == (sealedKept, 0), "ingest: the existing rule still withholds a whole assignment unit (no words sealed)")
    // Other kinds are not typed words: the scrubber leaves them to the existing rules.
    // Review finding: a terminal's title shows the command line, so Code
    // app titles go through the same scrubber; other apps' titles don't.
    var window = Evidence(id: "s-window", at: iso(now), kind: "window.changed", app: "Terminal", bundle: "com.apple.Terminal", title: "sudo apt update", synthetic: true)
    try check(try store.ingest(window, now: now) && store.read("s-window", now: now)?.evidence.title == "sudo \(m)", "ingest: a Code app's window title goes through the typed scrubber")
    window = Evidence(id: "s-window-notes", at: iso(now), kind: "window.changed", app: "Notes", bundle: "com.apple.Notes", title: "sudo apt update", synthetic: true)
    try check(try store.ingest(window, now: now) && store.read("s-window-notes", now: now)?.evidence.title == "sudo apt update", "ingest: other apps' titles keep the existing rules only")
    // Typing off: a secret-only unit writes nothing either.
    consent = try store.policy(); consent.captureText = false; try store.updatePolicy(consent, now: now)
    try check(try !store.ingest(typed("s-off", "482913"), now: now) && store.read("s-off", now: now) == nil, "ingest: typing off, a secret-only unit writes nothing")
}
