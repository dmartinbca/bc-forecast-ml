suppressPackageStartupMessages({
    library(forecast)
    library(dplyr)
})

`%||%` <- function(a, b) if (is.null(a) || length(a) == 0 || is.na(a)) b else a

pick_best <- function(ts_obj, h, methods) {
    fits <- list()
    for (m in methods) {
        fits[[m]] <- tryCatch({
            switch(m,
                "ets"   = ets(ts_obj),
                "arima" = auto.arima(ts_obj),
                "stl"   = stlf(ts_obj, h = h),
                "tbats" = tbats(ts_obj),
                NULL
            )
        }, error = function(e) NULL)
    }
    fits <- Filter(Negate(is.null), fits)
    if (length(fits) == 0) return(NULL)

    aics <- sapply(fits, function(f) tryCatch(AIC(f), error = function(e) Inf))
    best <- fits[[which.min(aics)]]
    forecast(best, h = h)
}

run_forecast <- function(data, horizon, seasonality, forecast_start, model = "ARIMA") {
    results <- list()
    freq <- max(as.integer(seasonality), 1L)
    model_up <- toupper(model)

    for (g in unique(data$GranularityAttribute)) {
        serie <- data %>%
            filter(GranularityAttribute == g) %>%
            arrange(DateKey)

        if (nrow(serie) < max(freq, 2)) next

        ts_obj <- ts(serie$TransactionQty, frequency = freq)

        fit <- tryCatch({
            switch(model_up,
                "ARIMA"     = forecast(auto.arima(ts_obj), h = horizon),
                "ETS"       = forecast(ets(ts_obj), h = horizon),
                "STL"       = stlf(ts_obj, h = horizon),
                "TBATS"     = forecast(tbats(ts_obj), h = horizon),
                "ETS+ARIMA" = pick_best(ts_obj, horizon, c("ets", "arima")),
                "ETS+STL"   = pick_best(ts_obj, horizon, c("ets", "stl")),
                "ALL"       = pick_best(ts_obj, horizon, c("ets", "arima", "stl", "tbats")),
                forecast(auto.arima(ts_obj), h = horizon)
            )
        }, error = function(e) NULL)

        if (is.null(fit)) next

        upper95 <- if (!is.null(fit$upper)) fit$upper[, ncol(fit$upper)] else rep(NA_real_, horizon)

        for (i in seq_len(horizon)) {
            results[[length(results) + 1L]] <- data.frame(
                GranularityAttribute = as.character(g),
                DateKey              = as.integer(forecast_start + i - 1L),
                Forecast             = as.numeric(fit$mean[i]),
                Delta                = as.numeric(upper95[i] - fit$mean[i]),
                stringsAsFactors     = FALSE
            )
        }
    }

    if (length(results) == 0) {
        return(data.frame(
            GranularityAttribute = character(),
            DateKey              = integer(),
            Forecast             = numeric(),
            Delta                = numeric(),
            stringsAsFactors     = FALSE
        ))
    }

    do.call(rbind, results)
}
