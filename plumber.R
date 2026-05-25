source("/app/forecast.R")
suppressPackageStartupMessages({
    library(plumber)
    library(jsonlite)
})

API_KEY <- Sys.getenv("API_KEY", "")

#* @filter checkAuth
function(req, res) {
    if (nchar(API_KEY) > 0 && req$PATH_INFO != "/") {
        auth <- req$HTTP_AUTHORIZATION %||% ""
        expected <- paste("Bearer", API_KEY)
        if (auth != expected) {
            res$status <- 401L
            return(list(error = "Unauthorized"))
        }
    }
    plumber::forward()
}

#* Health check (sin auth)
#* @get /
function() {
    list(status = "ok", service = "bc-forecast", version = "1.0", model = "R-forecast")
}

# Handler compartido entre /execute y /services.azureml.net/workspaces/<id>/execute
# (BC's AzureMLHelper.ValidateUri exige el path "services.azureml.net/workspaces/<guid>",
#  y luego concatena "/execute?api-version=2.0&details=true" en la request)
handle_forecast <- function(req, res) {
    body <- tryCatch(
        fromJSON(req$postBody, simplifyDataFrame = FALSE, simplifyVector = FALSE),
        error = function(e) NULL
    )
    if (is.null(body) || is.null(body$Inputs)) {
        res$status <- 400L
        return(list(error = "Invalid request body"))
    }

    in1 <- body$Inputs$input1
    in2 <- body$Inputs$input2
    if (is.null(in1) || is.null(in2)) {
        res$status <- 400L
        return(list(error = "Missing input1 or input2"))
    }

    rows <- lapply(in1$Values, function(r) {
        setNames(as.list(r), unlist(in1$ColumnNames))
    })
    df <- do.call(rbind.data.frame, c(rows, stringsAsFactors = FALSE))
    df$DateKey        <- as.integer(df$DateKey)
    df$TransactionQty <- as.numeric(df$TransactionQty)

    params <- setNames(
        as.list(in2$Values[[1]]),
        unlist(in2$ColumnNames)
    )
    horizon        <- as.integer(params$Horizon %||% 12)
    seasonality    <- as.integer(params$Seasonality %||% 12)
    forecast_start <- as.integer(params$Forecast_start_datekey %||% (max(df$DateKey) + 1L))
    model          <- as.character(params$TimeSeriesModel %||% "ARIMA")

    result <- run_forecast(df, horizon, seasonality, forecast_start, model)

    values <- if (nrow(result) == 0) {
        list()
    } else {
        unname(lapply(seq_len(nrow(result)), function(i) {
            list(
                as.character(result$GranularityAttribute[i]),
                as.integer(result$DateKey[i]),
                as.numeric(result$Forecast[i]),
                as.numeric(result$Delta[i])
            )
        }))
    }

    list(
        Results = list(
            output1 = list(
                type = "table",
                value = list(
                    ColumnNames = c("GranularityAttribute", "DateKey", "Forecast", "Delta"),
                    ColumnTypes = c("String", "Int32", "Double", "Double"),
                    Values = values
                )
            )
        )
    )
}

#* Forecast endpoint clasico (tests directos)
#* @post /execute
function(req, res) { handle_forecast(req, res) }

#* Endpoint compatible con BC: BC valida que la URL contenga 'services.azureml.net/workspaces/<guid>'
#* y concatena '/execute?api-version=2.0&details=true' antes de POSTear.
#* @post /services.azureml.net/workspaces/<workspaceId>/execute
function(workspaceId, req, res) { handle_forecast(req, res) }
