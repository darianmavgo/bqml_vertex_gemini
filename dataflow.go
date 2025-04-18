package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log" // Standard Go logger for job start/stop
	"net/http"
	"net/url" // Needed for tokeninfo URL query parameters
	"reflect"
	"strings" // Needed for trimming email response
	"sync"    // Needed for mutex in stateful DoFn
	"time"    // Needed for job duration logging & http client timeout

	"github.com/apache/beam/sdks/v2/go/pkg/beam"
	"github.com/apache/beam/sdks/v2/go/pkg/beam/io/bigqueryio"
	beamlog "github.com/apache/beam/sdks/v2/go/pkg/beam/log" // Beam logger
	"github.com/apache/beam/sdks/v2/go/pkg/beam/x/beamx"     // Needed for token source & scope constants
	"golang.org/x/oauth2/google"
)

var (
	// Default model can be overridden; ensure it's compatible with the predict endpoint
	modelName = flag.String("model_name", "gemini-pro", "Gemini model name (e.g., gemini-pro, gemini-1.0-pro)")
)

// --- Constants for BigQuery Output ---
const (
	outputDataset = "sandboxdataset"          // Your BigQuery dataset ID
	outputTable   = "gemini_dataflow_results" // Your BigQuery table ID
)

// --- Identity Helper Functions (Unchanged) ---

const metadataHost = "http://metadata.google.internal"
const metadataTimeout = 2 * time.Second // Short timeout for metadata check

func getMetadataServiceAccountEmail() (string, error) {
	// ... (implementation unchanged) ...
	client := &http.Client{
		Timeout: metadataTimeout,
	}
	url := fmt.Sprintf("%s/computeMetadata/v1/instance/service-accounts/default/email", metadataHost)
	req, err := http.NewRequest("GET", url, nil)
	if err != nil {
		return "", fmt.Errorf("failed to create metadata request: %w", err)
	}
	req.Header.Set("Metadata-Flavor", "Google")

	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to query metadata server (likely not running on GCP): %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("metadata server request failed with status %d: %s", resp.StatusCode, string(bodyBytes))
	}

	bodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read metadata response body: %w", err)
	}

	return strings.TrimSpace(string(bodyBytes)), nil
}

func getADCIdentityEmail(ctx context.Context) (string, error) {
	// ... (implementation unchanged) ...
	creds, err := google.FindDefaultCredentials(ctx, "https://www.googleapis.com/auth/userinfo.email")
	if err != nil {
		return "", fmt.Errorf("failed to find default credentials: %w", err)
	}

	token, err := creds.TokenSource.Token()
	if err != nil {
		return "", fmt.Errorf("failed to get token from token source: %w", err)
	}
	if !token.Valid() {
		return "", fmt.Errorf("retrieved token is invalid or expired")
	}

	tokenInfoURL := "https://www.googleapis.com/oauth2/v3/tokeninfo"
	reqUrl := fmt.Sprintf("%s?access_token=%s", tokenInfoURL, url.QueryEscape(token.AccessToken))

	resp, err := http.Get(reqUrl)
	if err != nil {
		return "", fmt.Errorf("failed to query tokeninfo endpoint: %w", err)
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		bodyBytes, _ := io.ReadAll(resp.Body)
		return "", fmt.Errorf("tokeninfo request failed with status %d: %s", resp.StatusCode, string(bodyBytes))
	}

	var info struct {
		Email         string `json:"email"`
		EmailVerified string `json:"email_verified"`
		Error         string `json:"error_description"`
	}
	if err := json.NewDecoder(resp.Body).Decode(&info); err != nil {
		return "", fmt.Errorf("failed to decode tokeninfo response: %w", err)
	}

	if info.Email == "" {
		if info.Error != "" {
			return "", fmt.Errorf("tokeninfo returned an error: %s", info.Error)
		}
		return "", fmt.Errorf("tokeninfo response did not contain an email address")
	}
	return info.Email, nil
}

// --- Data Structures ---

// Input prompt structure (unchanged)
type Prompt struct {
	Prompt string `beam:"Prompt"`
}

// Output result structure (unchanged)
type GeminiResult struct {
	Prompt        string `beam:"Prompt"`
	GeneratedText string `beam:"GeneratedText"`
}

// --- Vertex AI Request/Response Structs ---

type VertexInstance struct {
	Prompt string `json:"prompt"`
}

type VertexParameters struct {
	Temperature     float64 `json:"temperature"`
	TopK            int     `json:"topK"`
	MaxOutputTokens int     `json:"maxOutputTokens,omitempty"` // Optional: Example parameter
	// Add other parameters like TopP if needed
}

type VertexRequest struct {
	Instances  []VertexInstance `json:"instances"`
	Parameters VertexParameters `json:"parameters"`
}

type VertexPrediction struct {
	Content string `json:"content"`
	// SafetyAttributes map[string]interface{} `json:"safetyAttributes"` // Example if needed
	// CitationMetadata map[string]interface{} `json:"citationMetadata"` // Example if needed
}

type VertexResponse struct {
	Predictions []VertexPrediction `json:"predictions"`
	// Metadata map[string]interface{} `json:"metadata"` // Example if needed
}

// --- Stateful DoFn for Vertex AI call ---

const maxRedundantErrors = 20 // Cap for redundant errors per worker

// GenerateTextFn now includes projectID and region
type GenerateTextFn struct {
	ProjectID string // Added
	Region    string // Added
	ModelName string

	mu           sync.Mutex
	errorCounts  map[string]int
	ErrorCounter beam.Counter

	workerIdentity string
	identityErr    error
}

// Setup remains largely the same, initializes map and counter, determines identity
func (fn *GenerateTextFn) Setup(ctx context.Context) {
	fn.errorCounts = make(map[string]int)
	fn.ErrorCounter = beam.NewCounter("vertexai", "predict_errors_total") // Updated counter name

	// Determine worker identity (try metadata server first, fallback to ADC tokeninfo)
	email, err := getMetadataServiceAccountEmail()
	if err != nil {
		beamlog.Warnf(ctx, "GenerateTextFn: Failed to get identity from metadata server (%v), trying ADC tokeninfo fallback...", err)
		email, err = getADCIdentityEmail(ctx)
	}

	if err != nil {
		fn.identityErr = fmt.Errorf("failed to determine worker identity: %w", err)
		beamlog.Errorf(ctx, "GenerateTextFn: %v", fn.identityErr)
	} else {
		fn.workerIdentity = email
		beamlog.Infof(ctx, "GenerateTextFn: Worker setup complete. Project: %s, Region: %s, Model: %s, Identity: %s", fn.ProjectID, fn.Region, fn.ModelName, fn.workerIdentity)
	}
}

// ProcessElement calls the updated callVertexPredictAPI method
func (fn *GenerateTextFn) ProcessElement(ctx context.Context, p Prompt, emit func(GeminiResult)) {
	if fn.identityErr != nil {
		beamlog.Errorf(ctx, "GenerateTextFn: Skipping processing for prompt '%.50s...' due to worker identity error: %v", p.Prompt, fn.identityErr)
		return
	}

	// Call the renamed and updated API function
	result, err := fn.callVertexPredictAPI(ctx, p.Prompt)

	if err != nil {
		fn.ErrorCounter.Inc(ctx, 1)
		errorString := err.Error()
		fn.mu.Lock()
		count := fn.errorCounts[errorString]
		if count < maxRedundantErrors {
			// Updated error log message
			beamlog.Errorf(ctx, "GenerateTextFn: Error calling Vertex AI predict (identity: '%s', prompt: '%.50s...') (Count: %d): %v", fn.workerIdentity, p.Prompt, count+1, err)
			fn.errorCounts[errorString] = count + 1
		} else if count == maxRedundantErrors {
			beamlog.Warnf(ctx, "GenerateTextFn: Reached error cap (%d) for identity '%s' and Vertex AI error starting with: %.100s...", maxRedundantErrors, fn.workerIdentity, errorString)
			fn.errorCounts[errorString] = count + 1
		}
		fn.mu.Unlock()
		return
	}

	// beamlog.Infof(ctx, "GenerateTextFn: Successfully generated text via Vertex AI for prompt: %.50s...", p.Prompt)
	emit(GeminiResult{Prompt: p.Prompt, GeneratedText: result})
}

// callVertexPredictAPI handles the HTTP request to the Vertex AI predict endpoint.
func (fn *GenerateTextFn) callVertexPredictAPI(ctx context.Context, prompt string) (string, error) {
	// Use the broader cloud-platform scope, standard for most GCP APIs including Vertex AI
	client, err := google.DefaultClient(ctx, "https://www.googleapis.com/auth/cloud-platform")
	if err != nil {
		return "", fmt.Errorf("failed to create google default client (ADC issue?): %w", err)
	}

	// Construct the Vertex AI Predict endpoint URL
	// Example: https://us-central1-aiplatform.googleapis.com/v1/projects/my-project/locations/us-central1/publishers/google/models/gemini-pro:predict
	vertexPredictURL := fmt.Sprintf("https://%s-aiplatform.googleapis.com/v1/projects/%s/locations/%s/publishers/google/models/%s:predict",
		fn.Region, fn.ProjectID, fn.Region, fn.ModelName)

	// Construct the Vertex AI request body
	reqBody := VertexRequest{
		Instances: []VertexInstance{
			{Prompt: prompt},
		},
		Parameters: VertexParameters{
			Temperature: 0.8, // Example parameters - adjust as needed
			TopK:        3,
			// MaxOutputTokens: 256, // Uncomment or add if needed
		},
	}

	reqBytes, err := json.Marshal(reqBody)
	if err != nil {
		return "", fmt.Errorf("failed to marshal vertex request body: %w", err)
	}

	// Create and send the request
	req, err := http.NewRequestWithContext(ctx, "POST", vertexPredictURL, bytes.NewBuffer(reqBytes))
	if err != nil {
		return "", fmt.Errorf("failed to create http request for vertex ai: %w", err)
	}
	req.Header.Set("Content-Type", "application/json")

	resp, err := client.Do(req)
	if err != nil {
		return "", fmt.Errorf("failed to send request to vertex ai predict api: %w", err)
	}
	defer resp.Body.Close()

	respBodyBytes, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", fmt.Errorf("failed to read vertex response body: %w", err)
	}

	// Handle non-OK status codes
	if resp.StatusCode != http.StatusOK {
		// Attempt to parse standard Google API error structure for more details
		var googleApiError struct {
			Error struct {
				Code    int    `json:"code"`
				Message string `json:"message"`
				Status  string `json:"status"`
			} `json:"error"`
		}
		if json.Unmarshal(respBodyBytes, &googleApiError) == nil && googleApiError.Error.Message != "" {
			return "", fmt.Errorf("vertex ai predict api request failed with status %d (%s): %s",
				resp.StatusCode, googleApiError.Error.Status, googleApiError.Error.Message)
		}
		// Fallback to raw body if not standard error format
		return "", fmt.Errorf("vertex ai predict api request failed with status %d: %s", resp.StatusCode, string(respBodyBytes))
	}

	// Unmarshal the successful response
	var vertexResp VertexResponse
	if err := json.Unmarshal(respBodyBytes, &vertexResp); err != nil {
		return "", fmt.Errorf("failed to unmarshal vertex response (body: %.100s...): %w", string(respBodyBytes), err)
	}

	// Extract the content from the first prediction
	if len(vertexResp.Predictions) == 0 {
		beamlog.Warnf(ctx, "Received empty predictions list from Vertex AI for prompt: %.50s...", prompt)
		return "No prediction content from Vertex AI", nil // Indicate empty result
	}
	if vertexResp.Predictions[0].Content == "" {
		beamlog.Warnf(ctx, "Received empty content in first prediction from Vertex AI for prompt: %.50s...", prompt)
		return "Empty prediction content from Vertex AI", nil // Indicate empty content
	}

	return vertexResp.Predictions[0].Content, nil
}

// Teardown remains the same
func (fn *GenerateTextFn) Teardown(ctx context.Context) {
	beamlog.Infof(ctx, "GenerateTextFn Teardown complete for worker (Identity used: %s).", fn.workerIdentity)
}

// --- Pipeline Definition ---

// run function now takes projectID and region to pass to the DoFn
func run(p *beam.Pipeline, projectID, region, tempLocation, stagingLocation, model string) error { // Added region
	s := p.Root().Scope("GenerateNutritionLabels")

	// Step 1: Read Prompts from BigQuery (Unchanged)
	query := `
    SELECT CONCAT('generate nutrition label for ', products_brand_name) AS prompt
    FROM sandboxdataset.food_products
    LIMIT 100
`
	type PromptFromBQ struct {
		Prompt string `bigquery:"prompt"`
	}
	promptsFromBQ := bigqueryio.Query(s.Scope("ReadPrompts"),
		projectID,
		query,
		reflect.TypeOf(PromptFromBQ{}))

	// Step 2: Format prompts (Unchanged)
	prompts := beam.ParDo(s.Scope("FormatPrompts"),
		func(ctx context.Context, bqPrompt PromptFromBQ, emit func(Prompt)) {
			emit(Prompt{Prompt: bqPrompt.Prompt})
		}, promptsFromBQ)

	// Step 3: Call Vertex AI using the stateful DoFn
	// Pass projectID and region to the DoFn instance
	geminiFn := &GenerateTextFn{
		ProjectID: projectID,
		Region:    region,
		ModelName: model,
	}
	geminiResults := beam.ParDo(s.Scope("CallVertexAI"), geminiFn, prompts) // Renamed scope

	// Step 4: Write Results to BigQuery (Unchanged)
	tableName := fmt.Sprintf("%s:%s.%s", projectID, outputDataset, outputTable)
	bigqueryio.Write(s.Scope("WriteResults"), projectID, tableName, geminiResults)

	log.Println("Pipeline graph constructed successfully.")
	return nil
}

// --- Main Function ---

func main() {
	flag.Parse()
	beam.Init()

	ctx := context.Background()

	project := flag.Lookup("project").Value.String()
	if project == "" {
		log.Fatal("Missing required flag --project")
	}
	region := flag.Lookup("region").Value.String()
	if region == "" {
		log.Fatal("Missing required flag --region") // Region is now required for the Vertex AI endpoint
	}
	temp_location := flag.Lookup("temp_location").Value.String()
	if temp_location == "" {
		log.Fatal("Missing required flag --temp_location")
	}
	stagingLocation := flag.Lookup("staging_location").Value.String()
	if stagingLocation == "" {
		log.Println("Warning: Missing flag --staging_location, may be required for DataflowRunner")
	}
	model := *modelName

	// Determine and Log Launcher Identity (Unchanged)
	launcherIdentity := "unknown"
	identityEmail, err := getADCIdentityEmail(ctx)
	if err != nil {
		log.Printf("Warning: Could not determine launcher identity via ADC: %v", err)
	} else {
		launcherIdentity = identityEmail
	}
	log.Printf("Launcher Identity (determined via ADC): %s", launcherIdentity)

	// Job Start Logging (Unchanged)
	log.Printf("Starting Dataflow job...")
	log.Printf("  Project: %s", project)
	log.Printf("  Region: %s", region) // Log region
	log.Printf("  Temp Location: %s", temp_location)
	log.Printf("  Staging Location: %s", stagingLocation)
	log.Printf("  Model Name: %s (using Vertex AI endpoint)", model) // Updated log
	log.Printf("  Output Table: %s:%s.%s", project, outputDataset, outputTable)
	startTime := time.Now()

	p := beam.NewPipeline()
	// Pass region to the run function
	if err := run(p, project, region, temp_location, stagingLocation, model); err != nil {
		log.Fatalf("Failed to construct the pipeline graph: %v", err)
	}

	if err := beamx.Run(ctx, p); err != nil {
		endTime := time.Now()
		log.Printf("Pipeline failed after %v.", endTime.Sub(startTime))
		log.Fatalf("Failed to execute pipeline: %v", err)
	}

	// Job Stop Logging (Unchanged)
	endTime := time.Now()
	log.Printf("Pipeline finished successfully.")
	log.Printf("Total execution time: %v.", endTime.Sub(startTime))

	bqTableURL := fmt.Sprintf("https://console.cloud.google.com/bigquery?project=%s&page=table&d=%s&p=%s&t=%s",
		project, outputDataset, project, outputTable)
	log.Printf("BigQuery results table URL: %s", bqTableURL)

}
