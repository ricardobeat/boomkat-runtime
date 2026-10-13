import { useEffect, useState } from "preact/hooks";
import { api } from "../lib/api.js";
import { errorMessage } from "../lib/errors.js";
import { Icon, Modal } from "./common.js";
import type { Team, User } from "../../types.ts";

export function Members({
	team,
	user,
	close,
}: {
	team: Team;
	user: User;
	close: () => void;
}) {
	const [members, setMembers] = useState<User[]>([]),
		[error, setError] = useState(""),
		[busy, setBusy] = useState(false);
	async function load() {
		try {
			setMembers(await api<User[]>(`/teams/${team.id}/members`));
		} catch (e) {
			setError(errorMessage(e));
		}
	}
	useEffect(() => {
		load();
	}, [team.id]);
	async function add(e: Event) {
		e.preventDefault();
		const form = e.currentTarget as HTMLFormElement;
		setBusy(true);
		setError("");
		try {
			await api(`/teams/${team.id}/members`, "POST", {
				email: new FormData(form).get("email"),
			});
			form.reset();
			await load();
		} catch (e) {
			setError(errorMessage(e));
		} finally {
			setBusy(false);
		}
	}
	async function remove(member: User) {
		if (!confirm(`Remove ${member.name} from ${team.name}?`)) return;
		try {
			await api(`/teams/${team.id}/members/${member.id}`, "DELETE");
			await load();
		} catch (e) {
			setError(errorMessage(e));
		}
	}
	return (
		<Modal title={team.name} close={close}>
			<p class="muted">Good work starts with good people.</p>
			<div class="members">
				{members.map((m) => (
					<div key={m.id} class="member">
						<span class="avatar">{m.name[0].toUpperCase()}</span>
						<div>
							<strong>{m.name}</strong>
							<small>{m.email}</small>
						</div>
						{m.id === team.owner_id ? (
							<span class="pill">Owner</span>
						) : (
							team.owner_id === user.id && (
								<button
									class="icon-button"
									onClick={() => remove(m)}
									aria-label={`Remove ${m.name}`}
								>
									<Icon name="close" />
								</button>
							)
						)}
					</div>
				))}
			</div>
			{team.owner_id === user.id && (
				<form onSubmit={add}>
					<label>
						Add someone by email
						<input
							type="email"
							name="email"
							placeholder="teammate@example.com"
							required
						/>
					</label>
					<p class="hint">They’ll need to create an account first.</p>
					<button class="primary" disabled={busy}>
						Add to team
						<Icon name="plus" />
					</button>
				</form>
			)}
			{error && (
				<p class="error" role="alert">
					{error}
				</p>
			)}
		</Modal>
	);
}
