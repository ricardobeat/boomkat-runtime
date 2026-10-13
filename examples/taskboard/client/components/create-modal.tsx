import { useState } from "preact/hooks";
import { errorMessage } from "../lib/errors.js";
import { Modal } from "./common.js";

export function CreateModal({
	kind,
	close,
	save,
}: {
	kind: string;
	close: () => void;
	save: (name: string) => Promise<void>;
}) {
	const [busy, setBusy] = useState(false),
		[error, setError] = useState("");
	async function submit(e: Event) {
		e.preventDefault();
		setBusy(true);
		try {
			await save(
				String(new FormData(e.currentTarget as HTMLFormElement).get("name")),
			);
			close();
		} catch (e) {
			setError(errorMessage(e));
		} finally {
			setBusy(false);
		}
	}
	return (
		<Modal title={`New ${kind}`} close={close}>
			<form onSubmit={submit}>
				<label>
					{kind} name
					<input
						name="name"
						required
						maxLength={80}
						autoFocus
						placeholder={
							kind === "team" ? "Your next collaboration" : "Give it a name"
						}
					/>
				</label>
				{error && (
					<p class="error" role="alert">
						{error}
					</p>
				)}
				<button class="primary" disabled={busy}>
					{busy ? "Creating…" : `Create ${kind}`}
				</button>
			</form>
		</Modal>
	);
}
