import type { ExtensionAPI, ExtensionContext, WorkingIndicatorOptions } from "@earendil-works/pi-coding-agent";

const W = 18;
const MATRIX_CHARS = "ﾊﾐﾋｰｳｼﾅﾓﾆｻﾜﾂｵﾘ012789Z";
const GLITCH_CHARS = "█▓▒░╳╱╲¥£€$#@!?&%~*";

function rgb(r: number, g: number, b: number) {
	return `\x1b[38;2;${r};${g};${b}m`;
}
const RESET = "\x1b[39m";

function generateMatrixFrames(count: number): string[] {
	const frames: string[] = [];
	for (let f = 0; f < count; f++) {
		let line = "";
		for (let i = 0; i < W; i++) {
			const char = MATRIX_CHARS[Math.floor(Math.random() * MATRIX_CHARS.length)]!;
			const intensity = (i - f + count * 2) % (W / 2);
			let color = rgb(0, 80, 0);
			if (intensity < 1) color = rgb(0, 255, 0);
			else if (intensity < 3) color = rgb(0, 160, 0);
			line += color + char;
		}
		frames.push(line + RESET);
	}
	return frames;
}

function generateGlitchFrames(count: number): string[] {
	const colors = [rgb(0, 255, 200), rgb(255, 0, 100), rgb(100, 200, 255), rgb(255, 255, 0)];
	const frames: string[] = [];
	for (let f = 0; f < count; f++) {
		let line = "";
		for (let i = 0; i < W; i++) {
			const color = colors[Math.floor(Math.random() * colors.length)]!;
			const char = GLITCH_CHARS[Math.floor(Math.random() * GLITCH_CHARS.length)]!;
			line += color + char;
		}
		frames.push(line + RESET);
	}
	return frames;
}

const matrixFrames = generateMatrixFrames(30);
const glitchFrames = generateGlitchFrames(30);

export default function (pi: ExtensionAPI) {
	const matrixIndicator: WorkingIndicatorOptions = {
		frames: matrixFrames,
		intervalMs: 80,
	};
	
	const glitchIndicator: WorkingIndicatorOptions = {
		frames: glitchFrames,
		intervalMs: 60,
	};

	let activeTools = 0;

	pi.on("session_start", async (_event, ctx) => {
		activeTools = 0;
		ctx.ui.setWorkingIndicator(matrixIndicator);
	});

	pi.on("tool_execution_start", async (_event, ctx) => {
		activeTools++;
		ctx.ui.setWorkingIndicator(glitchIndicator);
	});

	pi.on("tool_execution_end", async (_event, ctx) => {
		activeTools--;
		if (activeTools <= 0) {
			activeTools = 0;
			ctx.ui.setWorkingIndicator(matrixIndicator);
		}
	});
}