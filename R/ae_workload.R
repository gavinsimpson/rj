#' Summarise the reviewer's agree/decline ratio based on past invites
#'
#' The function pulls out the agree/decline incidence of all the reviewers
#' based on past invite and calculate the agree percentage of each reviewer.
#' Use \code{tabulate_articles} first to tabulate all the articles in a particular directory
#' and then apply this function.
#'
#' @param articles a tibble summary of articles in the accepted and submissions folder. Output of \code{tabulate_articles()}
#' @param push whether the reviewer number of review completed by the reviewer should be pushed to the reviewer sheet
#' @importFrom tidyr separate_rows pivot_wider
#' @importFrom stringr str_detect word
#' @importFrom scales label_percent
#' @examples
#' \dontrun{
#' articles <- tabulate_articles()
#' reviewer_summary(articles)
#' }
#' @export
reviewer_summary <- function(articles, push = FALSE){
  res <- articles %>%
    dplyr::select(id, reviewers) %>%
    tidyr::unnest(reviewers) %>%
    tidyr::separate_rows(comment, sep = "; ") %>%
    dplyr::filter(stringr::str_detect(comment, "Agreed|Declined")) %>%
    dplyr::mutate(comment = tolower(stringr::word(comment))) %>%
    dplyr::group_by(name, comment) %>%
    dplyr::count() %>%
    dplyr::ungroup() %>%
    tidyr::pivot_wider(names_from = comment, values_from = n, values_fill = 0) %>%
    dplyr::relocate(name, agreed, declined) %>%
    dplyr::mutate(ratio = agreed / (agreed + declined),
                  ratio = scales::label_percent()(ratio))

  if (push){
    sheet_raw <- read_reviewer_sheet()
    out <- sheet_raw %>%
      dplyr::left_join(res %>% dplyr::select(name, agreed), by = c("fname" = "name")) %>%
      dplyr::select(agreed)
    range <- paste0("I1:I", nrow(sheet_raw))
    googlesheets4::range_write(reviewer_sheet_url, out, range = range)
  }

  res
}

#' @rdname ae_workload
#' @param x a single article, i.e. as.article("Submissions/2020-114")
#' @examples
#' \dontrun{
#' art <- as.article("Submissions/2020-114")
#' get_AE(art)
#' }
#' @export
get_AE <- function(x){
  list(id = format(x$id), ae = x$ae)
}

#' Check the number of articles an AE is currently working on
#'
#' This will examine the DESCRIPTION files for articles in
#' the Submissions folder, check articles that have status
#' "with AE".
#'
#' @param articles a tibble summary of articles in the accepted and submissions
#'   folder. Output of \code{tabulate_articles()}
#' @param day_back numeric; positive number of day to go back for calculating AE
#'   workload. Retains any article where any status entry for an article is
#'   newer than `day_back` days ago.
#'
#' @importFrom dplyr select count left_join filter distinct rename bind_rows
#' @importFrom tidyr unnest
#' @importFrom tibble as_tibble
#' @examples
#' \dontrun{
#' ae_workload()
#' }
#' @export
ae_workload <- function(articles = NULL, day_back = NULL) {
  ae_rj <- read.csv(system.file("associate-editors.csv", package = "rj")) %>%
    select(name, initials, email) %>%
    as_tibble()

  # if don't supply articles, use documented(!) source
  if (is.null(articles)) {
    articles <- tabulate_articles()
  }

  # throw away most of the columns & then unnest status
  articles <- articles %>%
    select(id, ae, status) %>%
    unnest(status)

  # filter articles if day back is provided
  # allow this to be NULL but check if is a numeric if supplied
  if (!is.null(day_back)) {
    stopifnot(is.numeric(day_back))
    articles <- articles %>%
      filter(date >= Sys.Date() - day_back)
  }

  # take only those with "with_AE" status & return rows
  # after this we don't need comments or status
  assignments <- articles %>%
    filter(status == "with AE", ae != "") %>%
    select(-c(comments, status)) %>%
    distinct(id, .keep_all = TRUE)

  # some people use names, other initials for AEs
  # this finds those with only initials and replace the ae with the full name
  tmp <- assignments %>%
    filter(str_length(ae) < 4) %>%
    left_join(ae_rj, by = c("ae" = "initials")) %>%
    select(id, name, date) %>%
    rename(ae = name)

  # ... which allows us to take all those with full names...
  assignments %>%
    filter(str_length(ae) >= 4) %>%
    bind_rows(tmp) %>% #... bind on those that had initials
    count(ae, sort = TRUE) %>% # count the assignments by AE
    left_join(ae_rj, by = c("ae" = "name")) # add some some useful info
}

#' Add AE to the DESCRIPTION
#'
#' Fuzzy match to find the initial of the AE to fill in the article DESCRIPTION.
#' The status field is also updated with a new line of add AE.
#'
#' @param article article id
#' @param name a name used to match AE, can be AE initials, name, github handle, or email
#' @param date the date for updating status
#' @export
add_ae <- function(article, name, date = Sys.Date()){
  article <- as.article(article)

  ae_list <- read.csv(system.file("associate-editors.csv", package = "rj")) #%>%
    #mutate(concat = paste0(!!sym("name"), !!sym("github_handle"), !!sym("email")))

  found <- NA
  # Check if matches initials
  found <- which(str_detect(ae_list$initials, name))
  # If not initials, check name
  if (is.na(found))
    found <- which(str_detect(ae_list$name, name))
  # If not initials, check github
  if (is.na(found))
    found <- which(str_detect(ae_list$github, name))
  # If not initials, check email
  if (is.na(found))
    found <- which(str_detect(ae_list$email, name))

  #person <- ae_list$github[str_detect(ae_list$concat, name)]
  #person_name <- as.character(ae_list$name[str_detect(ae_list$concat, name)])

  if (!is.na(found)){
    # github start with "ae-articles-xxx"
    #ae_abbr <- str_sub(person, 13, -1)
    article$ae <- ae_list$initials[found]
    update_status(article, "with AE", comments = ae_list$name[found], date = date)

  } else {
    cli::cli_alert_warning("No AE found. Input the name as the whole or part of the AE name, github handle, or email")
  }

  return(invisible(article))
}


#' Extract corresponding author from an article
#' @param article Article id, like \code{"2014-01"}
#' @examples
#' \dontrun{
#' # extract from a single article
#' corr_author("Submissions/2020-114")
#'
#' # extract corresponding authors from the active articles
#' all <- active_articles()
#' purrr::map_dfr(all, corr_author)
#' }
#' @importFrom purrr pluck map
#' @importFrom tibble tibble
#' @export
corr_author <- function(article){

  article <- as.article(article)

  all_authors <- article$authors
  # find the index of the author that provide the email
  email <- purrr::map(1:length(all_authors), ~purrr::pluck(all_authors, .x)$email)
  idx <- which(purrr::map_lgl(email, ~!is_null(.x)))

  tibble::tibble(
    corr_author = purrr::pluck(all_authors, idx)$name,
    email = purrr::pluck(all_authors, idx)$email
  )

}
