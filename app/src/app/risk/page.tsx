export const metadata = { title: "Risk disclosure — Mirrorbook" };

export default function Risk() {
  return (
    <div className="prose" style={{ maxWidth: 820 }}>
      <h1>Risk disclosure</h1>
      <p>
        Mirrorbook is open-source, experimental software that lets anyone run or follow on-chain portfolios of tokenized
        stocks. It is not a broker, adviser, fund or custodian, and nothing in this interface is investment, legal or tax
        advice. You can lose some or all of the money you deposit. Read this page fully before following a manager.
      </p>

      <h2>Manager risk</h2>
      <ul>
        <li>Managers are anonymous third parties. A past track record — even a verified on-chain one — does not predict future results.</li>
        <li>Guardrails bound, but do not remove, a manager&apos;s ability to lose money: each trade may lose up to the vault&apos;s slippage limit versus the oracle price, up to the daily trade limit, and concentrated positions can fall sharply.</li>
        <li>Managers can raise fees or loosen guardrails only after a 7-day notice period; watch vaults you follow and exit if you disagree.</li>
        <li>A &quot;Verified&quot; badge only means the manager staked the project token, which can be slashed by governance after an exploit. It is not an endorsement.</li>
      </ul>

      <h2>Tokenized-stock risk</h2>
      <ul>
        <li>Stock tokens are debt instruments issued by a third party that give price exposure to an underlying share. They do not grant shareholder rights, and their availability is restricted in many jurisdictions (including the U.S., Canada, the U.K. and Switzerland, among others). It is your responsibility to ensure you are eligible.</li>
        <li>Token prices can deviate from the underlying share price, and corporate actions (dividends, splits) are reflected through a multiplier that can pause the price oracle temporarily.</li>
        <li>On-chain liquidity for stock tokens may be thin; large trades can be impossible within the slippage limit.</li>
      </ul>

      <h2>Market hours and exits</h2>
      <ul>
        <li>Stablecoin deposits and withdrawals require live prices: while the stock market is closed (weekends, holidays) or an oracle is stale, cash exits from vaults holding stocks are disabled.</li>
        <li>An in-kind exit is always available: you receive your pro-rata share of every vault holding (stablecoin and stock tokens). You must then sell those tokens yourself.</li>
        <li>Cash withdrawals are limited to the vault&apos;s idle stablecoin; vaults may impose a minimum holding period of up to 7 days.</li>
        <li>Follower stops are executed by third-party keepers on a best-effort basis. They can execute late, or not at all, and may exit in kind.</li>
      </ul>

      <h2>Smart-contract, oracle and chain risk</h2>
      <ul>
        <li>The contracts have not been formally audited. Bugs could lead to the loss of all deposited funds.</li>
        <li>Valuations rely on Chainlink price feeds. Stale, incorrect or manipulated prices can lead to wrong valuations, fees or stop triggers. The protocol rejects stale, non-positive, out-of-band and abruptly jumping prices, but cannot guarantee correctness.</li>
        <li>The network is a Layer-2 rollup with a centralized sequencer; outages, reorgs or censorship can delay or block transactions.</li>
        <li>Protocol parameters are controlled by governance through a 48-hour timelock; a guardian can pause deposits and trading (never in-kind exits).</li>
      </ul>

      <h2>Fees</h2>
      <p>
        Managers may charge up to 2% per year in management fees and up to 25% of profits above the high-water mark. The
        protocol takes a share of those fees (at most 30%). All caps are enforced in code. Fees are taken by minting vault
        shares, which dilutes followers by the fee amount.
      </p>

      <h2>No warranty</h2>
      <p>
        The software is provided &quot;as is&quot;, without warranty of any kind. By using it you accept these risks and agree that
        you are solely responsible for your decisions and for complying with the laws that apply to you.
      </p>
    </div>
  );
}
