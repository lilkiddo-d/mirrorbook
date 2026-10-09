export const metadata = { title: "Unavailable in your region — Mirrorbook" };

export default function Blocked() {
  return (
    <div className="panel" style={{ maxWidth: 640 }}>
      <h1>Not available in your region</h1>
      <p className="muted">
        This interface is not offered in your jurisdiction. The underlying smart contracts are public, but we do not
        provide access to them from restricted regions. See the <a href="/risk">risk disclosure</a> for details.
      </p>
    </div>
  );
}
