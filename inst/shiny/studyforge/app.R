# StudyForge local app: free, offline by default (no API key).
library(shiny)
library(studyforge)

examples <- c(
  "I have 324 sorghum accessions for a GWAS at three sites, two reps per site, five plants per plot.",
  "I have 200 Arabidopsis accessions for flowering time in 48-cell trays and can't replicate everything.",
  "Antibiotics vs control in the drinking water, 10 mice per group housed 5 per cage.",
  "Lifespan of wild-type Dahomey females on 3 yeast concentrations."
)

ui <- fluidPage(
  titlePanel("StudyForge: experimental design assistant"),
  sidebarLayout(
    sidebarPanel(
      textAreaInput("q", "Describe your experiment", value = examples[1], rows = 6, width = "100%"),
      selectInput("ex", "...or load an example", choices = c("", examples)),
      radioButtons("provider", "Answer engine",
                   c("Local (free, offline, no AI)" = "local",
                     "Ollama (free local AI, must be installed)" = "ollama")),
      actionButton("go", "Design it", class = "btn-primary"),
      hr(),
      helpText("All numbers come from deterministic R code. StudyForge never assumes effect sizes or variances.")
    ),
    mainPanel(
      tabsetPanel(
        tabPanel("Plan", verbatimTextOutput("plan")),
        tabPanel("Setup checks", tableOutput("hazards")),
        tabPanel("Starter layout",
                 helpText("Generated from the starter code with placeholder names; edit and rerun in R for your real entries."),
                 tableOutput("layout"), downloadButton("dl", "Download layout CSV")),
        tabPanel("StudySpec (JSON)", verbatimTextOutput("spec"))
      )
    )
  )
)

server <- function(input, output, session) {
  observeEvent(input$ex, if (nzchar(input$ex)) updateTextAreaInput(session, "q", value = input$ex))
  ans <- eventReactive(input$go, studyforge_ask(input$q, provider = input$provider), ignoreNULL = FALSE)
  layout <- reactive({
    env <- new.env()
    tryCatch({
      eval(parse(text = ans()$recipe), envir = env)
      obj <- mget(c("field", "trays", "vials", "book"), envir = env, ifnotfound = list(NULL))
      Filter(Negate(is.null), obj)[[1]]
    }, error = function(e) data.frame(message = conditionMessage(e)))
  })
  output$plan <- renderPrint(print(ans()))
  output$hazards <- renderTable({
    hz <- ans()$hazards
    if (!length(hz)) return(data.frame(note = "No setup checks for this system yet."))
    data.frame(hazard = vapply(hz, `[[`, "", "hazard"),
               do_this = vapply(hz, function(h) paste(unlist(h$mitigation), collapse = "; "), ""),
               record = vapply(hz, function(h) paste(unlist(h$record), collapse = ", "), ""),
               source = vapply(hz, `[[`, "", "source"))
  })
  output$layout <- renderTable(utils::head(layout(), 50))
  output$dl <- downloadHandler("studyforge_layout.csv", function(file) utils::write.csv(layout(), file, row.names = FALSE))
  output$spec <- renderText(jsonlite::toJSON(ans()$spec, auto_unbox = TRUE, pretty = TRUE, null = "null"))
}

shinyApp(ui, server)
