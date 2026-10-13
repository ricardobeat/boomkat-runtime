import { useState } from "preact/hooks";
import { api } from "../lib/api.js";
import { errorMessage } from "../lib/errors.js";
import { Icon, Logo } from "./common.js";
import type { Session } from "../../types.ts";

export function Auth({ signedIn }: { signedIn: (s: Session) => void }) {
	const [signup, setSignup] = useState(false),
		[busy, setBusy] = useState(false),
		[error, setError] = useState("");
	async function submit(e: Event) {
		e.preventDefault();
		const f = new FormData(e.currentTarget as HTMLFormElement);
		setBusy(true);
		setError("");
		try {
			signedIn(
				await api<Session>(signup ? "/register" : "/login", "POST", {
					name: f.get("name"),
					email: f.get("email"),
					password: f.get("password"),
				}),
			);
		} catch (e) {
			setError(errorMessage(e));
		} finally {
			setBusy(false);
		}
	}
	return (
		<div class="auth-page">
			<header class="auth-header">
				<Logo />
				<span>A little space. A lot of possibility.</span>
			</header>
			<main class="auth-main">
				<section class="auth-story">
					<span class="eyebrow">MAKE ROOM FOR WHAT’S NEXT</span>
					<h1>
						Good ideas
						<br />
						need a place
						<br />
						<span>to grow.</span>
					</h1>
					<p>
						Bring your people, plans, and projects together.
						<br />
						One board at a time.
					</p>
					<div class="mini-board" aria-hidden="true">
						<div>
							<span class="mini-label">IDEAS</span>
							<div class="mini-card peach">
								A fresh perspective<span>● ●</span>
							</div>
							<div class="mini-card">Something worth making</div>
						</div>
						<div>
							<span class="mini-label">IN THE MAKING</span>
							<div class="mini-card lavender">
								The next big thing<span>↗</span>
							</div>
						</div>
						<div>
							<span class="mini-label">OUT IN THE WORLD</span>
							<div class="mini-card mint">
								A small win<span>✓</span>
							</div>
						</div>
					</div>
					<span class="story-foot">Less juggling. More doing.</span>
				</section>
				<section class="auth-panel">
					<span class="eyebrow">YOUR WORKSPACE AWAITS</span>
					<h2>{signup ? "Start something good." : "Welcome back."}</h2>
					<p>
						{signup
							? "Create an account and make it yours."
							: "Pick up where you left off."}
					</p>
					<form onSubmit={submit}>
						{signup && (
							<label>
								Your name
								<input
									name="name"
									required
									maxLength={80}
									autoComplete="name"
									placeholder="Alex Morgan"
								/>
							</label>
						)}
						<label>
							Email address
							<input
								type="email"
								name="email"
								required
								autoComplete="email"
								placeholder="you@example.com"
							/>
						</label>
						<label>
							Password
							<input
								type="password"
								name="password"
								required
								minLength={signup ? 15 : 1}
								maxLength={1024}
								autoComplete={signup ? "new-password" : "current-password"}
								placeholder={
									signup ? "At least 15 characters" : "Your password"
								}
							/>
						</label>
						{error && (
							<p class="error" role="alert">
								{error}
							</p>
						)}
						<button class="primary" disabled={busy}>
							{busy
								? "One moment…"
								: signup
									? "Create your workspace"
									: "Sign in"}
							<Icon name="arrow" />
						</button>
					</form>
					<p class="auth-switch">
						{signup ? "Already have an account?" : "New around here?"}{" "}
						<button
							class="text-button"
							onClick={() => {
								setSignup(!signup);
								setError("");
							}}
						>
							{signup ? "Sign in" : "Create an account"}
						</button>
					</p>
				</section>
			</main>
			<footer class="auth-footer">A calmer way to get things done.</footer>
		</div>
	);
}
