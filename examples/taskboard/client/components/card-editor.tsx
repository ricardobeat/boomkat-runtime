import { useState } from "preact/hooks";
import { api, uploadImage } from "../lib/api.js";
import { errorMessage } from "../lib/errors.js";
import { Icon, Modal } from "./common.js";
import type { Card, BoardData, Image } from "../../types.ts";

export function CardEditor({
	card,
	data,
	close,
	changed,
}: {
	card: Card;
	data: BoardData;
	close: () => void;
	changed: () => Promise<void>;
}) {
	const [error, setError] = useState(""),
		[busy, setBusy] = useState(false),
		[color, setColor] = useState(card.color),
		[uploading, setUploading] = useState(false);
	const images = data.images.filter((i) => i.card_id === card.id);
	async function save(e: Event) {
		e.preventDefault();
		const f = new FormData(e.currentTarget as HTMLFormElement);
		setBusy(true);
		setError("");
		try {
			await api(`/cards/${card.id}`, "PATCH", {
				title: f.get("title"),
				description: f.get("description"),
				list_id: Number(f.get("list_id")),
				color,
			});
			await changed();
			close();
		} catch (e) {
			setError(errorMessage(e));
		} finally {
			setBusy(false);
		}
	}
	async function remove() {
		if (!confirm("Delete this card and its images?")) return;
		setBusy(true);
		try {
			await api(`/cards/${card.id}`, "DELETE");
			await changed();
			close();
		} catch (e) {
			setError(errorMessage(e));
			setBusy(false);
		}
	}
	async function upload(e: Event) {
		const input = e.currentTarget as HTMLInputElement,
			file = input.files?.[0];
		if (!file) return;
		if (file.size > 5 * 1024 * 1024) {
			setError("Images must be under 5 MiB");
			return;
		}
		setUploading(true);
		setError("");
		try {
			await uploadImage(card.id, file);
			await changed();
		} catch (e) {
			setError(errorMessage(e));
		} finally {
			setUploading(false);
			input.value = "";
		}
	}
	async function removeImage(image: Image) {
		if (!confirm(`Remove ${image.name}?`)) return;
		try {
			await api(`/images/${image.id}`, "DELETE");
			await changed();
		} catch (e) {
			setError(errorMessage(e));
		}
	}
	return (
		<Modal title="A closer look" close={close}>
			<form onSubmit={save}>
				<label>
					Card title
					<input
						name="title"
						defaultValue={card.title}
						maxLength={200}
						required
						autoFocus
					/>
				</label>
				<label>
					Description
					<textarea
						name="description"
						defaultValue={card.description}
						rows={5}
						maxLength={8000}
						placeholder="Add a little context, a big idea, or the next step…"
					/>
				</label>
				<div class="editor-row">
					<label>
						List
						<select name="list_id" defaultValue={card.list_id}>
							{data.lists.map((l) => (
								<option value={l.id} key={l.id}>
									{l.name}
								</option>
							))}
						</select>
					</label>
					<fieldset class="color-picker">
						<legend>Color</legend>
						{["none", "mint", "peach", "lavender", "sky"].map((c) => (
							<button
								type="button"
								key={c}
								class={`swatch ${c} ${color === c ? "selected" : ""}`}
								onClick={() => setColor(c)}
								aria-label={c === "none" ? "No color" : c}
								aria-pressed={color === c}
							>
								{color === c && <Icon name="check" />}
							</button>
						))}
					</fieldset>
				</div>
				<section class="attachments">
					<div class="section-label">
						<span>
							Images <span class="count">{images.length}</span>
						</span>
						<label class="upload-button">
							<Icon name="image" />
							{uploading ? "Uploading…" : "Attach image"}
							<input
								type="file"
								accept="image/png,image/jpeg,image/gif,image/webp"
								onChange={upload}
								disabled={uploading}
								aria-label="Attach image"
							/>
						</label>
					</div>
					<div class="image-grid">
						{images.map((image) => (
							<figure key={image.id}>
								<a
									href={`/api/images/${image.id}`}
									target="_blank"
									rel="noopener"
								>
									<img src={`/api/images/${image.id}`} alt={image.name} />
								</a>
								<figcaption>
									<span>{image.name}</span>
									<button
										type="button"
										class="icon-button"
										aria-label={`Remove ${image.name}`}
										onClick={() => removeImage(image)}
									>
										<Icon name="close" />
									</button>
								</figcaption>
							</figure>
						))}
					</div>
					<p class="hint">PNG, JPEG, GIF or WebP · up to 5 MiB each</p>
				</section>
				{error && (
					<p class="error" role="alert">
						{error}
					</p>
				)}
				<div class="modal-actions">
					<button
						type="button"
						class="danger text-button"
						disabled={busy || uploading}
						onClick={remove}
					>
						<Icon name="trash" />
						Delete card
					</button>
					<button class="primary" disabled={busy || uploading}>
						{busy ? "Saving…" : "Save changes"}
					</button>
				</div>
			</form>
		</Modal>
	);
}
