import streamlit as st
import json
import _snowflake
from typing import Any, Dict, List, Optional
from snowflake.snowpark.context import get_active_session
session = get_active_session()
from streamlit_extras.stylable_container import stylable_container
st.set_page_config(layout="wide",initial_sidebar_state='expanded')
st.write('<style>div.block-container{margin-top:0;padding-top:0;position:relative;top:-30px}</style>', unsafe_allow_html=True)

##############  MAKE CHANGES HERE for images, color, opacity  ##############

#vLogo = 'https://upload.wikimedia.org/wikipedia/commons/thumb/f/ff/Snowflake_Logo.svg/1024px-Snowflake_Logo.svg.png'
vLogo = 'https://upload.wikimedia.org/wikipedia/commons/thumb/f/ff/Snowflake_Logo.svg/1024px-Snowflake_Logo.svg.png'
vLogoWidth = 180
#vBackgroundImage = 'https://www.snowflake.com/wp-content/uploads/2022/10/SF_Cloud_Platform_2.jpeg'
vBackgroundImage = 'https://www.snowflake.com/wp-content/uploads/2022/10/SF_Cloud_Platform_2.jpeg'
vTextColor =  '#28B5E9'  # Enter named color like 'orange' or hex code #28B5E9
vSidebarBackgroundColor = '#28B5E9'  # Background color of left sidebar
vContainerColor = 'white'  # Assign either black or white
vContainerOpacity = 96  # Pick a value between 0 and 100 for percent opacity (0 transparent / 100 opaque)

# Set the values to be used for container rgb
if vContainerColor.capitalize() == 'White':
    vContainerColorCode = '255,255,255'
else:
    vContainerColorCode = '0,0,0'        

# Set background image
st.markdown("""<style>[data-testid=stAppViewContainer] 
                    {background-image: url(""" + vBackgroundImage + """);
                    background-repeat: no-repeat; background-size: 100% 100%;
                    }</style>""", unsafe_allow_html=True)

# Set all text colors (including for st.header, st.subheader, st.write, st.button, etc)
st.markdown("<style> h1, h2, h3, h4, h5, h6, a, p, span {color: " + vTextColor + ";} </style>", unsafe_allow_html=True)

# Set sidebar background color
st.markdown("<style>[data-testid=stSidebar] {background-color: " + vSidebarBackgroundColor + "}</style>", unsafe_allow_html=True)

st.image(vLogo, width=int(vLogoWidth))
st.write('')

############################################################################


def snowflake_api_call(query: str, limit: int = 10):
    API_ENDPOINT = "/api/v2/cortex/agent:run"
    API_TIMEOUT = 50000  # in milliseconds
    
    # Prepare the request body with the user's prompt
    payload = {
        "model": "claude-3-5-sonnet",
        "messages": [{"role": "user","content": [{"type": "text","text": query}]}],
        
        ##############  MAKE CHANGES HERE for your own services/yamls ##############
        "tools": [
            {"tool_spec": {"type": "cortex_analyst_text_to_sql","name": "Sales Analyst"}},
            {"tool_spec": {"type": "cortex_search","name": "Product Search"}}
            
        ],
        "tool_resources": {
            "Sales Analyst": {"semantic_model_file": '@CC_QUICKSTART_CORTEX_AGENTS.PUBLIC.semantic/sales_semantic.yaml'},
             "Product Search": {"name": 'CC_QUICKSTART_CORTEX_AGENTS.PUBLIC.CC_SEARCH_SERVICE_CS',"max_results": 5}
        }}   
        ############################################################################
    
    # Send a POST request to the Cortex Analyst API endpoint
    # Adjusted to use positional arguments as per the API's requirement
    resp = _snowflake.send_snow_api_request(
        "POST",  # method
        API_ENDPOINT,  # path
        {},  # headers
        {},  # params
        payload,  # body
        None,  # request_guid
        API_TIMEOUT,  # timeout in milliseconds
    )
    
    # Content is a string with serialized JSON object
    parsed_content = json.loads(resp["content"])
    return parsed_content


def display_content(
    event: List[Dict[str, str]],
    message_index: Optional[int] = None,
) -> None:
    """Displays a content item for a message."""
    message_index = message_index or len(st.session_state.messages)
    text = ""
    myresults = ""
    sql=""
    counter=1

    for content_item in event['data']['delta']['content']:
        content_type = content_item.get('type')
        if content_type == "tool_use":
            tool_use = content_item.get('tool_use', {})
            if counter == 1:
                vOutput2.subheader(tool_use["name"])
                counter += counter + 1

        if content_type == "text":
            myresults += content_item.get('text', {})
            return myresults
        if content_type == "tool_results":
            tool_results = content_item.get('tool_results', {})
            if 'content' in tool_results:
                for result in tool_results['content']:
                    if result.get('type') == 'json':
                        text += result.get('json', {}).get('text', '')
                        search_results = result.get('json', {}).get('searchResults', [])
                        for search_result in search_results:
                            text += f"\n• {search_result.get('text', '')}"
                        sql = result.get('json', {}).get('sql', '')
            if sql:
                st.write('')
                vOutput3.write("**Results**")
                df = session.sql(sql.replace(";",""))
                vOutput4.dataframe(df, use_container_width=True, hide_index=True)
                st.write('')
                with vOutput5.expander("**Generated SQL**"):
                    st.code(sql, language="sql")



with stylable_container(key='myContainer',css_styles="""
        {border-radius: 15px; gap: 10px; padding: 20px;
        box-shadow: 4px 4px 4px 1px """ + vContainerColor + """; 
        background-color: rgba(""" + vContainerColorCode + """,""" + str(vContainerOpacity/100) + """); 
        button{background-color:""" + vContainerColor + """;border-color: """ + vTextColor + """};
        table, th, td, ul, li, ol{color: """ + vTextColor + """; font-size: 14px;};
        }
        """):
        # Use small dummy second column to avoid objects pushing off right edge of container
        c1, c2 = st.columns([1000,1])
        with c1:
    
            ################################################
            ##   Enter your main application code below   
            ################################################
            st.header("AI Assistant")
            st.write("Search your tables and/or documents with one simple ask")

            # Initialize session state
            if 'messages' not in st.session_state:
                st.session_state.messages = []
                
            # Chat input form
            if vChat := st.chat_input('Enter your inquiry here'):
                vOutput1 = st.empty()
                vOutput2 = st.empty()
                vOutput3 = st.empty()
                vOutput4 = st.empty()
                vOutput5 = st.empty()
                vOutput6 = st.empty()

                vOutput1.caption('Results for your inquiry \'***' + vChat + '***\':')
                # Add user message to chat
                st.session_state.messages.append({"role": "user", "content": vChat})
                
                # Process query
                with st.spinner("Processing your request..."):
                    response = snowflake_api_call(vChat)
                    # uncomment below to preview/troubleshoot the full returnset
                    # response
                    allResults = ""
                    for i in response:
                        if i['data']!="[DONE]":
                            try:
                                allResults += display_content(event=i)
                            except:
                                st.write()
            
                    vOutput6.write(allResults.replace("•", "\n\n-"))
                        

