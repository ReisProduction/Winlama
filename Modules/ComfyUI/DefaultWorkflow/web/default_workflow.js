import { app } from "../../scripts/app.js";
import { api } from "../../scripts/api.js";
const workflowPath = "workflows/Wan2.1_T2V_Workflow.json";
async function loadDefaultWorkflow() {
    try {
        if (Array.isArray(app.graph?._nodes) &&
            app.graph._nodes.length > 0) {
            return;
        }
        const response = await api.getUserData(workflowPath);
        if (!response.ok) {
            return;
        }
        const workflow = await response.json();
        if (!Array.isArray(workflow.nodes) ||
            !Array.isArray(workflow.links)) {
            return;
        }
        await app.loadGraphData(workflow);
    } catch (error) {
        console.error("WINLAMA_DEFAULT_WORKFLOW_LOAD_FAILED", error);
    }
}
function scheduleDefaultWorkflow() {
    window.setTimeout(loadDefaultWorkflow, 1500);
}
app.registerExtension({
    name: "Winlama.DefaultWorkflow",
    async setup() {
        if (window.location.search || window.location.hash) {
            return;
        }
        if (document.readyState === "complete") {
            scheduleDefaultWorkflow();
            return;
        }
        window.addEventListener(
            "load",
            scheduleDefaultWorkflow,
            { once: true }
        );
    }
});