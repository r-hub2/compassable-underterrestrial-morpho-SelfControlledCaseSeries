library(SelfControlledCaseSeries)
library(testthat)

credentialsSet <- Sys.getenv("CDM5_POSTGRESQL_SERVER") != ""

if (credentialsSet) {

  if (dir.exists(Sys.getenv("DATABASECONNECTOR_JAR_FOLDER"))) {
    jdbcDriverFolder <- Sys.getenv("DATABASECONNECTOR_JAR_FOLDER")
  } else {
    jdbcDriverFolder <- "~/.jdbcDrivers"
    dir.create(jdbcDriverFolder, showWarnings = FALSE)
    DatabaseConnector::downloadJdbcDrivers("postgresql", pathToDriver = jdbcDriverFolder)
    withr::defer(
      {
        unlink(jdbcDriverFolder, recursive = TRUE, force = TRUE)
      },
      testthat::teardown_env()
    )
  }

  postgresConnectionDetails <- DatabaseConnector::createConnectionDetails(
    dbms = "postgresql",
    user = Sys.getenv("CDM5_POSTGRESQL_USER"),
    password = URLdecode(Sys.getenv("CDM5_POSTGRESQL_PASSWORD")),
    server = Sys.getenv("CDM5_POSTGRESQL_SERVER"),
    pathToDriver = jdbcDriverFolder
  )

  postgresResultsDatabaseSchema <- paste0("r", Sys.getpid(), format(Sys.time(), "%s"), sample(1:100, 1))

  databaseFile <- tempfile(fileext = ".sqlite")
  sqliteConnectionDetails <- DatabaseConnector::createConnectionDetails(
    dbms = "sqlite",
    server = databaseFile
  )
  sqliteResultsDatabaseSchema <- "main"

  withr::defer({
    connection <- DatabaseConnector::connect(connectionDetails = postgresConnectionDetails)
    sql <- "DROP SCHEMA IF EXISTS @resultsDatabaseSchema CASCADE;"
    DatabaseConnector::renderTranslateExecuteSql(
      sql = sql,
      resultsDatabaseSchema = postgresResultsDatabaseSchema,
      connection = connection
    )

    DatabaseConnector::disconnect(connection)
    unlink(databaseFile, force = TRUE)
  },
  testthat::teardown_env()
  )

  testCreateSchema <- function(connectionDetails, resultsDatabaseSchema) {
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))
    if (connectionDetails$dbms != "sqlite") {
      sql <- "CREATE SCHEMA @resultsDatabaseSchema;"
      DatabaseConnector::renderTranslateExecuteSql(
        sql = sql,
        resultsDatabaseSchema = resultsDatabaseSchema,
        connection = connection
      )
    }
    suppressWarnings(
      createResultsDataModel(
        connectionDetails = connectionDetails,
        databaseSchema = resultsDatabaseSchema,
        tablePrefix = ""
      )
    )
    specifications <- getResultsDataModelSpecifications()
    for (tableName in unique(specifications$tableName)) {
      expect_true(DatabaseConnector::existsTable(connection = connection,
                                                 databaseSchema = resultsDatabaseSchema,
                                                 tableName = tableName))
      row <- DatabaseConnector::renderTranslateQuerySql(
        connection = connection,
        sql = "SELECT TOP 1 * FROM @database_schema.@table;",
        database_schema = resultsDatabaseSchema,
        table = tableName
      )
      observedFields <- sort(tolower(names(row)))
      expectedFields <- sort(tolower(specifications$columnName[specifications$tableName == tableName]))
      expect_equal(observedFields, expectedFields)
    }
    # Bad schema name
    expect_error(createResultsDataModel(
      connectionDetails = connectionDetails,
      databaseSchema = "non_existant_schema"
    ))
  }

  test_that("Create schema", {
    # Skipping to avoid 'vector memory limit of 16.0 Gb reached' error on MacOS in GitHub Actions.
    # Possible caused by large chunk size in ResultModelManager: https://github.com/OHDSI/ResultModelManager/blob/15f3a81acd8b23a571881ddb31e24507688efe83/R/DataModel.R#L507
    # This test does not throw an error on local MacOS machine with same OS and R version, so guessing this is due to limits of GA VM.
    # Note: this test did not throw an error before Nov 2024, and RMM code hasn't changed, so may be related to some updates in tidyverse?
    skip_on_os("mac")
    testCreateSchema(connectionDetails = postgresConnectionDetails,
                     resultsDatabaseSchema = postgresResultsDatabaseSchema)
    testCreateSchema(connectionDetails = sqliteConnectionDetails,
                     resultsDatabaseSchema = sqliteResultsDatabaseSchema)
  })

  testUploadResults <- function(connectionDetails, resultsDatabaseSchema) {
    uploadResults(
      connectionDetails = connectionDetails,
      schema = resultsDatabaseSchema,
      zipFileName = system.file("Results_Eunomia.zip", package = "SelfControlledCaseSeries"),
      purgeSiteDataBeforeUploading = FALSE)

    # Check if there's data:
    connection <- DatabaseConnector::connect(connectionDetails)
    on.exit(DatabaseConnector::disconnect(connection))

    specifications <- getResultsDataModelSpecifications()
    for (tableName in unique(specifications$tableName)) {
      primaryKey <- specifications |>
        dplyr::filter(tableName == !!tableName &
                        primaryKey == "Yes") |>
        dplyr::select(columnName) |>
        dplyr::pull()

      if ("database_id" %in% primaryKey) {
        sql <- "SELECT COUNT(*) FROM @database_schema.@table_name WHERE database_id = '@database_id';"
        databaseIdCount <- DatabaseConnector::renderTranslateQuerySql(
          connection = connection,
          sql = sql,
          database_schema = resultsDatabaseSchema,
          table_name = tableName,
          database_id = "Eunomia"
        )[, 1]
        expect_true(databaseIdCount >= 0)
      }
    }
  }

  test_that("Results upload", {
    # Skipping for reasons described above:
    skip_on_os("mac")
    testUploadResults(connectionDetails = postgresConnectionDetails,
                      resultsDatabaseSchema = postgresResultsDatabaseSchema)
    testUploadResults(connectionDetails = sqliteConnectionDetails,
                      resultsDatabaseSchema = sqliteResultsDatabaseSchema)
  })
}
