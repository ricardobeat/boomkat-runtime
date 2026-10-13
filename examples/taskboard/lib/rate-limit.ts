import { fail } from "./errors.ts";

export function createAuthLimiter() {
	// Bound both global password work (native) and repeated attempts per account.
	const attempts = new Map<string, { count: number; expires: number }>();
	let globalAttempts = { count: 0, expires: 0 };
	function limitAuth(key: string) {
		const now = Date.now();
		if (globalAttempts.expires <= now)
			globalAttempts = { count: 0, expires: now + 60000 };
		if (++globalAttempts.count > 30)
			fail(429, "Too many sign-in attempts. Try again in a minute");
		if (attempts.size > 1000)
			for (const [k, v] of attempts) if (v.expires <= now) attempts.delete(k);
		if (!attempts.has(key) && attempts.size >= 1000)
			fail(429, "Too many sign-in attempts. Try again later");
		let a = attempts.get(key);
		if (!a || a.expires <= now) {
			a = { count: 0, expires: now + 600000 };
			attempts.set(key, a);
		}
		if (++a.count > 10)
			fail(429, "Too many attempts for this account. Try again in ten minutes");
	}

	return limitAuth;
}
