# https://stackoverflow.com/questions/48324165/scraping-table-from-xml

library(tidyverse)
library(stringi)
library(xml2)

url_location <- # can browse all files
  "ftp://ftp.cdc.gov/pub/Health_Statistics/NCHS/Publications/ICD10CM/"

xml_doc <- paste0(url_location, "2021/icd10cm_tabular_2021.xml")
  #"R/mock_up_example/mock_icd.xml"

load_xml <- read_xml(xml_doc)


# chapters ----
chapter_nodes <- xml_find_all(load_xml, ".//chapter")
icd_chapters <-
  tibble(
    chapter = xml_text(xml_find_first(chapter_nodes, ".//name")),
    chapter_desc = xml_text(xml_find_first(chapter_nodes, ".//desc"))
  ) %>% 
  mutate(
    chapter = str_remove_all(chapter_desc, ".*\\(|\\)"),
    category = chapter,
    #chapter_desc = trimws(str_extract(chapter_desc, "[^\\(]+"))
  ) %>% 
    separate_rows(category)



# sections ----
section_nodes <- xml_find_all(load_xml, ".//section")
icd_sections <-
  tibble(
    section = xml_attr(section_nodes, "id"),
    section_desc = xml_text(xml_find_first(section_nodes, ".//desc"))
  ) %>% 
  mutate(
    section = str_remove_all(section_desc, ".*\\(|\\)"),
    category = section
  ) %>% 
  separate_rows(category) %>% 
  group_by(category) %>% 
  slice_tail(n = 1) %>% 
  ungroup()

# dx ----
parse_dx <- function(n, title, join_field) {
  # need to grab //diag/diag/diag x # of times
  rep_n <- ifelse(n == 3, 1, n - 2)
  
  xpath <-
    paste0(
      ".//",
      paste(rep("diag", rep_n), collapse = "/")
    )

  # pulls back description etc
  dx_nodes <- xml_find_all(load_xml, xpath)

  
  tibble(
    dx = xml_find_first(dx_nodes, "name") %>% xml_text(),
    desc = xml_find_first(dx_nodes, "desc") %>% xml_text(),
    join = 
      str_sub(dx, 1, -2) %>% # remove last character
      str_remove("\\.$")  # remove trailing period
  ) %>%
    # dx_nodes brings back all dx below this level
    # this will ensure we just have the codes of length n
    filter(nchar(str_remove(dx, "\\.")) == n) %>% 
    # rename columns
    select(
      "{title}" := dx,
      "{title}_desc" := desc,
      "{join_field}" := join # will be used in full_joins()
    )
}

icd_dx <-
  parse_dx(7, "extension", "subcategory_3") %>%
  full_join(parse_dx(6, "subcategory_3", "subcategory_2")) %>%
  full_join(parse_dx(5, "subcategory_2", "subcategory_1")) %>%
  full_join(parse_dx(4, "subcategory_1", "category")) %>%
  full_join(parse_dx(3, "category", "supercategory")) %>%
  mutate(
    icd10_code = 
      coalesce(extension, subcategory_3, subcategory_2, subcategory_1, category)
  ) %>%
  select(
    icd10_code, 
    starts_with("category"), 
    matches("1"), 
    matches("2"), 
    matches("3"), 
    matches("extension")
  ) %>%
  arrange(icd10_code)


# extensions ----
ext_node <- xml_find_all(load_xml, ".//diag/sevenChrDef/extension")
icd_extensions <-
  tibble(
    name = xml_find_first(ext_node, "../../name") %>% xml_text(),
    note = xml_find_first(ext_node, "../../sevenChrNote/note") %>% xml_text(),
    char = xml_attr(ext_node, "char"),
    text = xml_text(ext_node)
  )

# full dataset
prep_extensions <-
  icd_extensions %>%
  mutate( # extract referenced code patterns
    applies_to =
      note %>%
        str_remove_all("O30") %>%
        # expand to S12.1, S12.2, etc
        str_replace("S12.0-S12.6", paste0("S12.", 0:6, collapse = ", ")) %>%
        # pull out dx codes
        str_extract_all("[A-Z]\\d{2}([\\.A-Z0-9]+)?")
  ) %>%
  unnest(applies_to) %>%
  mutate( # create fields to join to in next step
    applies_to = str_remove(applies_to, "\\.$"),
    length = nchar(applies_to),
    category = ifelse(length == 3, str_sub(applies_to, 1, 3), NA),
    subcategory_1 = ifelse(length == 5, str_sub(applies_to, 1, 5), NA),
    subcategory_2 = ifelse(length == 6, str_sub(applies_to, 1, 6), NA)
  )



# see what it looks like
prep_extensions %>%
  group_by(note) %>%
  summarise(
    n = n_distinct(applies_to),
    codes = paste(unique(applies_to), collapse = ", "),
    chars = paste(unique(char), collapse = ", ")
  ) %>%
  ungroup() %>%
  filter(n > 1) #%>% 
  # mutate(
  #   note = str_remove_all(note, "The appropriate 7th character is to be added to|One of the following 7th characters is to be assigned to( each)? code(s in subcategory)?|to designate ((lateral|sever)ity|the stage) of (the disease|glaucoma)")
  # )


join_dx <- function(df, join_var, loc) {
  #df <- icd_dx %>% filter(icd10_code == "S42.311"); join_var <- quo(subcategory_2); loc <- 6; 
  df %>%
    # filter out any extension field that already has a value
    filter(across(starts_with("x"), is.na)) %>% 
    inner_join(
      prep_extensions %>%
        filter(length == loc) %>% 
        distinct(
          {{join_var}}, 
          "x{{loc}}" := char, 
          "x{{loc}}_desc" := text
        ) %>% 
        drop_na()
      #,by = deparse(substitute(join_var)) # creates string
    ) %>% 
    select(icd10_code, tail(names(.), 2)) %>% 
    distinct()
}

# with extensions ----
with_extensions <-
  icd_dx %>%
  # odd but need to bring over the code & text each time so not overwritten
  left_join(join_dx(., subcategory_2, 6)) %>% 
  left_join(join_dx(., subcategory_1, 5)) %>%
  left_join(join_dx(., category, 3)) %>%
#  filter(icd10_code == "S42.311") %>% 
  mutate(
    extension = coalesce(str_sub(extension, 8), x3, x5, x6),
    extension_desc = coalesce(extension_desc, x3_desc, x5_desc, x6_desc),
    icd10_code = 
      ifelse(
        test = nchar(icd10_code) == 3 & !is.na(extension), 
        yes = paste0(icd10_code, "."),
        no = icd10_code
      )
  ) %>%
  select(-starts_with("x")) %>% 
  mutate(
    icd10_code = # recompile icd10_code
      case_when(
        # some codes are 8 digits long w/o extension, keep as-is
        nchar(icd10_code) == 8 ~ icd10_code, 
        # pad code with Xs if less than 7 digits
        !is.na(extension) ~ paste0(str_pad(icd10_code, 7, "right", "X"), extension),
        TRUE ~ icd10_code
      )
  )

# final join ----
final_joins <- 
  with_extensions %>%
  left_join(icd_chapters) %>% 
  #  select(icd10_code, starts_with("x")) %>% 
  arrange(icd10_code) %>% 
  fill(chapter) %>% 
  fill(chapter_desc) %>% 
  left_join(icd_sections) %>% 
  fill(section) %>% 
  fill(section_desc) %>% 
  mutate(
    description =
      paste(
        coalesce(
          subcategory_3_desc, 
          subcategory_2_desc, 
          subcategory_1_desc, 
          category_desc
        ),
        replace_na(extension_desc, "")
      ) %>% tolower()
  ) %>%
  select(
    icd10_code, description, starts_with("chap"), starts_with("sect"), everything()
  )

  
  
find_difference <- function(x, y) {
  # df <- drop_na(final_joins, subcategory_3_desc)[3,]
  # x <- df$subcategory_3_desc
  # y <- df$subcategory_2_desc
  x <- str_remove_all(x, "[[:punct:]]")
  y <- 
    trimws(str_remove_all(y, "[[:punct:]]")) %>% 
    str_replace_all(" ", "|")
  
  x %>% 
    str_remove_all(y) %>% 
    str_replace_all(" {2,}", " ") %>% # remove double spaces
    trimws()
}

as_ascii <-
  final_joins %>% 
  #  filter(category == "S42") %>% select(icd10_code, matches("[y123]_desc")) %>% 
  mutate_all(stringi::stri_trans_general, "latin-ascii")


# final diagnoses ----
final_diagnoses <-
  as_ascii %>% 
#  filter(category == "S42") %>% select(icd10_code, matches("[y123]_desc")) %>% 
  mutate(across(matches("cat.*desc"), tolower)) %>% 
  mutate(
    subcategory_1_diff = find_difference(subcategory_1_desc, category_desc),
    subcategory_2_diff = find_difference(subcategory_2_desc, subcategory_1_desc),
    subcategory_3_diff = find_difference(subcategory_3_desc, subcategory_2_desc)
  ) #%>%select(ends_with("diff"))
  
# check for unique
final_diagnoses %>% 
  summarise(
    n = n(),
    n_icd = n_distinct(icd10_code),
    n_desc = n_distinct(description)
  ) # 72567

final_diagnoses[35000, ] %>% t()

write_csv(final_diagnoses, "output/icd10_diagnosis_hierarchy.csv", na = "")
